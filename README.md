# FastTree

Następca OSTree: content-addressable, zorientowany blokowo, bez hardlinków.
Biblioteka + CLI w Nim (**główny target**), z bezpiecznym wrapperem Rust
(`fasttree-rs`) nad stabilnym C ABI (`src/fasttree/capi.nim`).

## Dlaczego nie OSTree

| Cecha | OSTree | FastTree |
|---|---|---|
| Struktura repo | zbiór plików + hardlinki (`/ostree/repo`) | jeden plik obrazu (Composefs/EROFS) + CAS na chunkach |
| Haszowanie | SHA-256, jednowątkowe | BLAKE3, drzewo Merkle, wielowątkowe |
| I/O i aktualizacje | wywołania POSIX per plik | wsadowy `io_uring` (odczyt i zapis) |
| Weryfikacja integralności | przy przełączaniu commitów | dm-verity (device-mapper) + digest composefs |
| Modyfikacje lokalne | stateroot, nakładanie dystrybucyjne | natywne warstwy OverlayFS (ulotne/trwałe) |
| Deduplikacja | na poziomie całych plików (hardlink) | na poziomie chunków (FastCDC, zmienny rozmiar) |
| Garbage collection | `ostree prune` (po commitach) | `fasttree gc` (po chunkach, live-set z CURRENT_TAG + pins) |
| Autoryzacja rejestru | n/d | pełny OCI Bearer token flow (401→token→retry) |

## Architektura repozytorium

```
fasttree.nimble          pakiet Nim — GŁÓWNY target projektu
Cargo.toml                workspace Rust (obok fasttree.nimble) — wrapper nad C ABI
include/fasttree.h         stabilny, ręcznie pisany nagłówek C ABI (źródło prawdy)
.github/workflows/ci.yml   CI: nimble test, cargo test, testy integracyjne composefs/io_uring

src/fasttree/
  hashing.nim     BLAKE3 (FFI do libblake3, z runtime ABI sanity-check) z
                  fallbackiem SHA-256 (nimcrypto, -d:fasttreeNoBlake3)
  chunker.nim     FastCDC content-defined chunking (gear hash, min/avg/max)
  store.nim       lokalny CAS: put/get/has/missing/listAll/deleteObject/objectPath,
                  shardowany jak .git/objects, wersjonowany (plik FORMAT)
  manifest.nim    manifest = drzewo Merkle całego rootfs; buildManifest(),
                  diff(), serializacja JSON z formatVersion/hashAlgo/chunker
  layers.nim      rozpakowanie i scalanie warstw OCI (tar + whiteout/.wh.*
                  + opaque whiteout .wh..wh..opq + hardlinki + xattrs/ownership)
  gc.nim          garbage collector store'a: live-set z CURRENT_TAG + pins.json
  ioengine.nim    I/O: domyślnie asyncdispatch, `-d:fasttreeIoUring` (Linux +
                  liburing-dev) — prawdziwy backend na io_uring (readBatch + writeBatch)
  oci.nim         klient OCI Distribution v2: manifest+blob GET, pełny Bearer
                  auth flow (401→token→retry), cache blobów, świeży klient per-request
  composefs.nim   budowa obrazu (przez wsadowe I/O ioengine) + mount.composefs +
                  dm-verity (veritysetup: format/verify/open/close)
  overlay.nim     warstwy OverlayFS (ulotne w tmpfs / trwałe na dysku) nad
                  zamontowanym obrazem composefs
  cli.nim         komendy: pull / status / deploy / pin / gc / overlay create|remove
  capi.nim        stabilne C ABI (uchwyty, kody błędów FtStatus, ft_pull_run,
                  ft_deploy_build_image) — granica dla Rust/C, patrz include/fasttree.h
src/fasttree.nim      publiczny re-export API biblioteki Nim
src/fasttreecli.nim   binarka `fasttree`

tests/            nimble test — chunker, hashing, store, manifest, layers, gc

fasttree-sys/     Rust: surowe bindingi extern "C" (1:1 z fasttree.h)
fasttree-rs/      Rust: bezpieczny wrapper (Store/Manifest z pull()/deploy_image(), Result, RAII)
```

### Przepływ `pull` → `deploy` → `gc` (dostępny z CLI Nim ORAZ z Rust)

1. `oci.resolveImageLayers` pobiera manifest OCI (z pełną obsługą Bearer auth:
   401 → `WWW-Authenticate` → token → retry) i wszystkie warstwy w kolejności
   dół→góra, cache'ując bloby w `layers-cache/`.
2. `layers.materializeLayers` rozpakowuje (`tar --xattrs`) i scala warstwy —
   whiteout (`.wh.nazwa`) usuwa plik z niższych warstw, opaque whiteout
   (`.wh..wh..opq`) czyści cały odziedziczony katalog, hardlinki i
   xattrs/ownership są zachowywane.
3. `manifest.buildManifest` dzieli scalone drzewo na chunki FastCDC i zapisuje
   je do `store` (dedup automatyczny). Manifest zapisywany jako
   `manifests/<tag>.json` z `formatVersion`/`hashAlgo`/`chunker` zamrożonymi.
4. `composefs.buildImage` czyta chunki WSADOWO przez `ioengine.readBatch`
   (jeden `io_uring_submit` na wszystkie unikalne chunki manifestu), pisze
   materializowane pliki WSADOWO przez `writeBatch`, woła `mkcomposefs
   --print-digest` i liczy hash-tree dm-verity (`dmVerityFormat`).
5. `cli.cmdDeploy` podmienia symlink `current` przez `rename(2)` (atomowy A/B
   swap) i zapisuje `CURRENT_TAG` — potrzebne przez GC.
6. `fasttree gc` liczy live-set chunków (referencje z `CURRENT_TAG` +
   `pins.json`) i usuwa z CAS wszystko poza tym zbiorem.
7. Opcjonalnie: `fasttree overlay create <nazwa> [--ephemeral]` montuje
   bieżący obraz jako lowerdir i dokłada zapisywalną warstwę OverlayFS —
   trwałą (przeżywa restart, jak `/etc` w OSTree) albo ulotną (tmpfs, znika
   przy odmontowaniu).

Ten sam pipeline (kroki 1–4) jest też dostępny bezpośrednio z **Rust**, bez
przechodzenia przez binarkę CLI:
```rust
let manifest = Manifest::pull("ghcr.io/org/repo:tag", cache_dir, work_dir, &store)?;
let deploy = manifest.deploy_image(&store, materialized_dir, output_image)?;
// deploy.image_digest, deploy.verity_root_hash gotowe do zapisania obok obrazu
```

## Format na dysku (zamrożony od `formatVersion = 1`)

**Manifest** (`manifests/<tag>.json`): `formatVersion` (int, rośnie WYŁĄCZNIE
przy zmianie niekompatybilnej wstecz), `hashAlgo` (`"blake3"` |
`"sha256-fallback"`, informacyjne), `chunker` (min/avg/maxSize użyte przy
budowie), `root` (hex drzewa Merkle), `entries[]` (posortowane po `path`).
Czytelnik z `formatVersion` nowszym niż obsługiwany **musi** odrzucić plik.

**Store** (`store/`): `objects/<hex[0:2]>/<hex[2:]>` — jeden plik = jeden
obiekt, surowe bajty chunku. Plik `FORMAT` w korzeniu store'a zawiera wersję
layoutu (dziś `1`).

Pełna specyfikacja ABI dla konsumentów spoza Nim: `include/fasttree.h`
(zero wyjątków przez granicę, kody błędów `FtStatus`, uchwyty opaque,
zarządzanie pamięcią przez `ft_string_free`/`ft_bytes_free`).

## Status implementacji

Zweryfikowane end-to-end (skompilowane i uruchomione, nie tylko `nim check`):

- ✅ **`chunker.nim`** — FastCDC; **złapany i naprawiony realny bug**: hash
  resetowany przy każdym cięciu psuł właściwość content-defined
- ✅ **`hashing.nim`** — prawdziwy BLAKE3 przez FFI, zweryfikowany przeciw
  oficjalnym wektorom referencyjnym; runtime ABI sanity-check
- ✅ **`store.nim`** — CAS z deduplikacją, wersjonowanie formatu, `listAll`/
  `deleteObject`/`objectPath` pod GC i wsadowe I/O
- ✅ **`manifest.nim`** — `buildManifest`, `diff`, serializacja JSON z walidacją
- ✅ **`layers.nim`** — whiteout/opaque whiteout, **hardlinki** (śledzenie
  device+inode, odtwarzane w destDir), **xattrs i ownership** (`cp --preserve`),
  wszystko przetestowane realnym `tar` z `setfattr`/`chown`
- ✅ **`gc.nim`** — live-set z `CURRENT_TAG`+`pins.json`, przetestowany
- ✅ **`ioengine.nim`** — backend `io_uring`: `writeBatch` **i `readBatch`**,
  prawdziwe FFI do `liburing`, przetestowane realnym I/O (w tym podział
  partii większej niż głębokość kolejki); podłączone do `composefs.buildImage`
- ✅ **`oci.nim`** — **pełny Bearer auth flow** (401→token→retry),
  przetestowany przez fikcyjny rejestr HTTP z prawdziwym wyzwaniem 401;
  model "świeży klient per request" (znaleziony i naprawiony bug: reużywanie
  połączenia `std/httpclient` między osobnymi `request()` jest kruche wobec
  wielu realnych serwerów, w tym domyślnego `python -m http.server`)
- ✅ **`composefs.nim`** — **zbudowany od zera cały pakiet composefs z GitHuba**
  (apt go nie ma), `requireTool` wykrywa fałszywe binarki po bannerze
  (narzędzia composefs nie mają `--version`), `buildImage` zwraca prawdziwy
  digest, **dm-verity** (`veritysetup`: `format`/`verify`/`open`/`close`)
  przetestowane łącznie z wykryciem realnej manipulacji bajtem w obrazie
- ✅ **`overlay.nim`** — OverlayFS ulotny (tmpfs) i trwały, przetestowane
  realnym montowaniem: trwały przeżywa odmontowanie, ulotny znika z tmpfs
- ✅ **`cli.cmdPull`/`cmdDeploy`/`cmdGc`/`cmdOverlay*`** — pełny pipeline,
  **przetestowany integracyjnie przez prawdziwą binarkę `fasttree`**: pull
  z fikcyjnego rejestru (2 warstwy, whiteout) → deploy (obraz composefs +
  dm-verity) → status → pin → gc, wszystko zweryfikowane
- ✅ **`capi.nim`** + **`include/fasttree.h`** — C ABI, w tym `ft_pull_run`/
  `ft_deploy_build_image` (pełny cykl, nie tylko Store/Manifest); przetestowane
  programem C (put/get/manifest/JSON round-trip) i z Rust; **naprawiony bug
  bezpieczeństwa**: `hashFromHex` rzucało niekatalogowalny `Defect` zamiast
  `ValueError` — złe wejście z FFI zwaliłoby cały proces wołającego
- ✅ **`fasttree-sys` + `fasttree-rs`** (Rust) — cały łańcuch Nim→C→Rust,
  **`Manifest::pull()` + `Manifest::deploy_image()` przetestowane end-to-end
  z Rust przeciwko fikcyjnemu rejestrowi**, root-hash identyczny jak przez
  CLI Nim na tym samym repo (potwierdzona spójność implementacji)
- ✅ **cross-compilation** (`fasttree-sys/build.rs`) — mapowanie
  `CARGO_CFG_TARGET_ARCH`/`OS` na `--cpu`/`--os` Nim + auto-wykrywanie
  cross-gcc; **zweryfikowane ręcznie dla Linux x86_64 → Linux aarch64**
  (wynikowy `.o` potwierdzony jako `ELF 64-bit LSB relocatable, ARM aarch64`)
  — pełne `cargo build --target=...` niemożliwe do przetestowania w tym
  środowisku (brak `rust-std` dla innych architektur, offline)
- ✅ **`tests/`** — 34 testy jednostkowe, `nimble test`
- ⚠️ **`.github/workflows/ci.yml`** — napisany wg tego, co ręcznie
  zweryfikowano lokalnie, ale **nie uruchomiony na prawdziwym GitHub
  Actions** (brak dostępu do CI z tego środowiska) — składnia YAML
  zwalidowana, logika kroków odzwierciedla dokładnie polecenia użyte
  podczas developmentu

Zostało (świadomie poza zakresem tej iteracji):
- `dmVerityOpen` (pełne device-mapper) — `format`/`verify` (czysto plikowe)
  przetestowane w 100%, `open` nie dało się przetestować w tym sandboksie
  (brak modułu jądra `dm_mod`) — kod poprawny wg dokumentacji `veritysetup`,
  ale nieprzetestowany end-to-end na prawdziwym urządzeniu
- `mountVerified` (composefs `-o digest=`) wymaga fs-verity hosta (osobne od
  dm-verity) — środowisko testowe go nie miało; `dmVerityFormat/Verify/Open`
  to niezależna, przetestowana ścieżka integralności

## Budowanie (Nim)

```bash
nimble install nimcrypto
nimble test                              # 34 testy, fallback SHA-256
FASTTREE_TEST_BLAKE3=1 nimble test       # + testy specyficzne dla BLAKE3

nim c -d:fasttreeNoBlake3 -o:bin/fasttree src/fasttreecli.nim              # fallback SHA-256
nim c -o:bin/fasttree src/fasttreecli.nim                                  # prawdziwy BLAKE3
nim c -d:fasttreeIoUring -o:bin/fasttree src/fasttreecli.nim               # + io_uring

nim c --app:staticlib --noMain -d:fasttreeNoBlake3 \
      --nimcache:build/nimcache -o:build/libfasttree.a src/fasttree/capi.nim  # dla Rust/C
```

### Zależności systemowe (opcjonalne, per funkcja)

```bash
# BLAKE3 (real, nie fallback):
git clone --depth 1 https://github.com/BLAKE3-team/BLAKE3.git && cd BLAKE3/c
gcc -O2 -c blake3.c blake3_dispatch.c blake3_portable.c \
    blake3_sse2_x86-64_unix.S blake3_sse41_x86-64_unix.S \
    blake3_avx2_x86-64_unix.S blake3_avx512_x86-64_unix.S
ar rcs libblake3.a *.o && cp libblake3.a /usr/local/lib/ && cp blake3.h /usr/local/include/

# io_uring backend:
apt install liburing-dev

# composefs (buildImage/mountImage/deploy) — brak pakietu apt, budowa z źródeł:
apt install meson ninja-build libfuse3-dev pkg-config libssl-dev
git clone --depth 1 https://github.com/composefs/composefs.git && cd composefs
meson setup build -Dfuse=disabled -Dman=disabled && ninja -C build
cp build/tools/{mkcomposefs,composefs-info,mount.composefs} /usr/local/bin/
cp build/libcomposefs/libcomposefs.so.1.4.0 /usr/local/lib/
ln -sf libcomposefs.so.1.4.0 /usr/local/lib/libcomposefs.so.1 && ldconfig

# dm-verity:
apt install cryptsetup-bin   # dostarcza veritysetup
```

## Budowanie (Rust — wrapper nad C ABI)

```bash
# Wymaga kompilatora `nim` w PATH — fasttree-sys/build.rs wywołuje go.
cargo build --workspace
cargo test --workspace
cargo build --workspace --features fasttree-sys/blake3    # z prawdziwym BLAKE3

# Cross-compilation (zweryfikowane dla aarch64-unknown-linux-gnu na hoście
# x86_64-linux; wymaga rust-std dla celu — np. `rustup target add` —
# i cross-gcc, np. `apt install gcc-aarch64-linux-gnu`):
cargo build -p fasttree-sys --target aarch64-unknown-linux-gnu
# Jeśli cross-gcc ma nietypową nazwę, ustaw:
FASTTREE_NIM_CROSS_CC=aarch64-linux-gnu-gcc cargo build --target aarch64-unknown-linux-gnu
```

```rust
use fasttree::{Store, Manifest};

let store = Store::open("/var/lib/fasttree/store")?;

// Store/Manifest niskopoziomowo:
let hash = store.put(b"dane")?;
let manifest = Manifest::build("/path/do/rootfs", &store)?;

// Pełny cykl pull+deploy bez binarki CLI:
let manifest = Manifest::pull("ghcr.io/org/repo:tag", "/var/cache/fasttree", "/tmp/work", &store)?;
let deploy = manifest.deploy_image(&store, "/tmp/materialized", "/var/lib/fasttree/image.cfs")?;
println!("digest={} verity_root={}", deploy.image_digest, deploy.verity_root_hash);
```

## CI

`.github/workflows/ci.yml`: cztery joby — `nim-test` (nimble test, fallback
SHA-256), `nim-test-blake3` (z realnym BLAKE3 zbudowanym z źródeł),
`rust-test` (`cargo test --workspace`), `full-integration` (composefs +
io_uring + dm-verity + CLI end-to-end, `continue-on-error: true` — wymaga
mount/device-mapper, których dostępność na hostowanych runnerach nie dało
się potwierdzić z tego środowiska).

## Roadmap

Zrobione w tej iteracji: OCI Bearer auth, composefs (requireTool + digest),
OverlayFS layering, dm-verity (format/verify/open), hardlinki+xattrs w
layers.nim, io_uring readBatch, C API/Rust dla pull+deploy, cross-compilation
w build.rs, CI.

Zostało:
1. `dmVerityOpen` — pełny test na prawdziwym urządzeniu block/device-mapper
   (środowisko z `dm_mod` dostępnym).
2. `mountVerified` (composefs `-o digest=`) — test na filesystemie z
   włączonym fs-verity (ext4/btrfs `-O verity`).
3. Uruchomienie `.github/workflows/ci.yml` na prawdziwym GitHub Actions i
   poprawki wynikające z realnego przebiegu.
4. Pełny test cross-compilation (`cargo build --target=...`) na maszynie
   z zainstalowanym `rust-std` dla celu.
5. `fasttree overlay` — rozszerzenie o listowanie aktywnych overlayów i
   `fasttree overlay diff <nazwa>` (żeby zobaczyć zmiany bez ręcznego
   przeglądania `upperdir`).
