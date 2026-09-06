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
  przetestowane w 100%. Dodano `deviceMapperAvailable()` (preflight-check
  `/dev/mapper/control`) i test jednostkowy (`tests/test_composefs_capability.nim`)
  weryfikujący fast-fail z czytelnym błędem, gdy device-mapper niedostępny —
  **potwierdzone empirycznie w tym środowisku** (`veritysetup open` faktycznie
  kończy się `Cannot initialize device-mapper. Is dm_mod kernel module
  loaded?`, dokładnie jak przewidywał wcześniejszy komentarz w kodzie).
  `.github/workflows/ci.yml` (`full-integration`) ma teraz dedykowany krok
  (`modprobe dm_mod` + realny `dmVerityOpen`/`dmVerityClose`), który na
  GitHub-hosted `ubuntu-latest` (pełna maszyna wirtualna, nie zagnieżdżony
  kontener) ma szansę faktycznie przejść — pozostaje do potwierdzenia na
  prawdziwym runnerze.
- `mountVerified` (composefs `-o digest=`) wymaga fs-verity hosta (osobne od
  dm-verity) — środowisko testowe go nie miało. Dodano `fsVerityKernelSupport()`
  (preflight-check `CONFIG_FS_VERITY` w `/boot/config-$(uname -r)`) z tym
  samym testem jednostkowym. `.github/workflows/ci.yml` ma teraz krok, który
  buduje ext4 z `-O verity` w pliku pętli i próbuje `fsverity enable` +
  `mountVerified` naprawdę — **w tym środowisku krok przeszedł aż do próby
  `fsverity enable`, która zwróciła `Operation not supported`** (jądro
  sandboksa nie ma `CONFIG_FS_VERITY`), więc kod poprawnie i bezpiecznie
  pominął resztę zamiast fałszywie zaliczyć test. `dmVerityFormat/Verify/Open`
  to niezależna, przetestowana ścieżka integralności.
- Oba powyższe kroki CI, plus istniejący test composefs+dm-verity
  format/verify, zostały **faktycznie uruchomione lokalnie w tym środowisku**
  (zbudowano `composefs` z źródeł, zainstalowano `cryptsetup-bin`/`fsverity`) —
  przy okazji znaleziono i naprawiono dwa niezależne bugi w `ci.yml`
  niewykryte wcześniej (patrz "Poprawki w tej iteracji" niżej). Sam
  `full-integration` job w tej postaci nadal nie był uruchomiony na
  prawdziwym GitHub Actions.

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

Zrobione w kolejnej iteracji (patrz "Poprawki w tej iteracji" niżej):
`status --diff`, `overlay list`/`overlay diff`, preflight-checki dla
dm-verity/fs-verity + testy jednostkowe, rozszerzenie CI o realne próby
`dmVerityOpen`/`mountVerified`, dwie poprawki bugów w `ci.yml`.

Zostało:
1. Uruchomienie `dmVerityOpen`/`mountVerified` (nowe kroki CI) na prawdziwym
   GitHub Actions — lokalnie potwierdzone, że kod poprawnie działa/pomija się
   w zależności od możliwości jądra, ale sam runner GH Actions jest
   niepotwierdzony.
2. Uruchomienie `.github/workflows/ci.yml` na prawdziwym GitHub Actions i
   poprawki wynikające z realnego przebiegu (poza dwoma już znalezionymi i
   naprawionymi bugami — patrz niżej).
3. Pełny test cross-compilation (`cargo build --target=...`) na maszynie
   z zainstalowanym `rust-std` dla celu — offline w tym środowisku (brak
   dostępu do `static.rust-lang.org` w konfiguracji sieciowej sandboksu).

## Poprawki w tej iteracji

Wszystkie poniższe zweryfikowane empirycznie (skompilowane i uruchomione,
nie tylko `nim check`) w środowisku z zainstalowanym `nim`/`nimble` z apt:

- **`cli.cmdStatus --diff`** — był stubem (`echo "TODO"`). Podpięty pod
  istniejący `manifest.diff()`; dodano śledzenie `PREVIOUS_TAG` w
  `cmdDeploy`. Przetestowane na dwóch manifestach — poprawnie pokazuje
  added/removed/modified z liczbą chunków.
- **`fasttree overlay list` / `overlay diff <nazwa>`** — nowe komendy
  (`overlay.listActiveOverlays`, wpięcie istniejącego `overlay.listChanges`
  pod CLI). Przetestowane realnym montowaniem overlayfs (trwały + ulotny) —
  poprawne rozróżnienie zamontowany/niezamontowany po ręcznym `umount`.
- **`ioengine.nim`** — usunięty nieaktualny komentarz odsyłający do
  rozwiązanego już TODO w `composefs.nim`.
- **`composefs.deviceMapperAvailable()` / `fsVerityKernelSupport()`** —
  nowe preflight-checki przed `dmVerityOpen`/`mountVerified`, dające czytelny
  błąd od razu zamiast czekać na cryptyczny komunikat z `veritysetup`/
  `mount.composefs`. Pokryte testem jednostkowym
  (`tests/test_composefs_capability.nim`, wchodzi w skład `nimble test`).
- **Dwa niezależne, wcześniej nieznane bugi w `ci.yml`**, znalezione przez
  faktyczne uruchomienie kroków lokalnie: (1) wzorzec `nim c -r /dev/stdin
  <<'NIM'` nie działa w tej wersji Nim (`Error: cannot open '/dev/stdin.nim'`)
  — zamieniony na zapis do pliku tymczasowego; (2) treść heredoc dziedziczyła
  wcięcie YAML-a, co dawało `Error: invalid indentation` na poziomie modułu
  Nim — naprawione przez `sed` usuwający wspólny prefiks przed kompilacją.
  Oba potwierdzone jako realny problem I jako naprawione: zbudowano
  `composefs` z źródeł w tym środowisku i pełny test `buildImage` +
  `dmVerityFormat`/`dmVerityVerify` przeszedł po poprawce.
- **Błędna nazwa pakietu w nowym kroku CI** — `fsverity-utils` nie istnieje
  w Ubuntu; poprawna nazwa to `fsverity` (potwierdzone `apt-cache search`).
- **`nimble tags`** — pole `tags` NIE istnieje w składni `.nimble` (próba
  dodania go rzuca `Error: undeclared identifier: 'tags'`, potwierdzone
  uruchomieniem `nimble test`). Tagi należą do wpisu w rejestrze
  `nim-lang/packages` (`packages.json`), nie do samego pakietu — patrz
  `packaging/README.md` i `packaging/nimble-packages-entry.json`.
- **`fasttree-sys`/`fasttree-rs` (Cargo) — build był całkowicie zepsuty.**
  Zgłoszone przez użytkownika po realnym uruchomieniu `cargo build --release`
  na maszynie z Nim 2.2.10. Kolejne łatanie objawów (zmiana `[lib] name`
  na wersję z podkreślnikiem) prowadziło tylko do kolejnych błędów
  (`unresolved import`, `no matching package found`) — bo **prawdziwą
  przyczyną było `crate-type = ["staticlib"]`** na obu crate'ach. Staticlib
  nie generuje `.rlib`, więc `fasttree-rs` fizycznie nie mogło zrobić
  zwykłego `use fasttree_sys`. Żaden z tych crate'ów nie eksportuje własnego
  `extern "C" fn` — jedyny prawdziwy plik `.a` w tym układzie to
  `libfasttree.a` skompilowany z Nima przez `build.rs`, i tak już linkowany
  bezpośrednio (`cargo:rustc-link-lib=static=fasttree`), całkowicie
  niezależnie od `crate-type` samych crate'ów Rust. Naprawa: usunięcie całej
  sekcji `[lib]` z `fasttree-sys/Cargo.toml` i `fasttree-rs/Cargo.toml`
  (domyślny `rlib` w zupełności wystarcza), bez ruszania `[package] name`
  (który zgodnie z konwencją Cargo może i powinien mieć myślnik — to
  wyłącznie nazwa TARGETU biblioteki musi być poprawnym identyfikatorem
  Rusta). Zweryfikowane end-to-end: `cargo build --release` +
  `cargo test --release` (8/8 testów, w tym prawdziwy roundtrip store
  put/get przez FFI do skompilowanego Nima) przechodzą od razu, bez
  dalszych poprawek.
