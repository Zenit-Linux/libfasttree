import std/[json, options, os, sequtils]
import ./hashing
import ./store as storeMod
import ./manifest as manifestMod
import ./gc as gcMod
import ./oci as ociMod
import ./layers as layersMod
import ./composefs as composefsMod

# --- Kody błędów -------------------------------------------------------------

type FtStatus* {.exportc: "FtStatus", size: sizeof(cint).} = enum
  ftOk = 0
  ftErrInvalidArgument = 1
  ftErrIo = 2
  ftErrNotFound = 3
  ftErrFormat = 4          ## niezgodność formatVersion manifestu/store'u
  ftErrInternal = 5        ## wyjątek Nim inny niż powyższe — patrz ft_last_error()

var lastErrorMsg {.threadvar.}: string
  ## Komunikat błędu dla ostatniego wywołania NA TYM WĄTKU. Wzorzec identyczny
  ## z `errno`/`GetLastError()` — bo zwracanie stringa przez wartość zwrotną
  ## kolidowałoby z tym, że wartość zwrotna to już kod statusu.

proc ft_last_error*(): cstring {.exportc, dynlib, cdecl.} =
  lastErrorMsg.cstring

template ftGuard(body: untyped): FtStatus =
  ## Łapie WSZYSTKIE wyjątki Nim i mapuje je na FtStatus — patrz zasada (2)
  ## w komentarzu modułu. Umieszczane w każdej eksportowanej funkcji.
  try:
    body
    ftOk
  except storeMod.StoreFormatError as e:
    lastErrorMsg = e.msg; ftErrFormat
  except manifestMod.ManifestFormatError as e:
    lastErrorMsg = e.msg; ftErrFormat
  except ValueError as e:
    lastErrorMsg = e.msg; ftErrInvalidArgument
  except IOError as e:
    lastErrorMsg = e.msg; ftErrIo
  except CatchableError as e:
    lastErrorMsg = e.msg; ftErrInternal

# --- Zarządzanie buforami zwracanymi wołającemu ------------------------------

proc ft_string_free*(s: cstring) {.exportc, dynlib, cdecl.} =
  ## MUSI być wołane na każdym cstring zwróconym przez ft_*_to_json /
  ## ft_*_hex — te bufory są alokowane allocShared-em Nim, nie libc malloc.
  if s != nil:
    deallocShared(cast[pointer](s))

proc toOwnedCstring(s: string): cstring =
  ## Kopiuje string Nim do bufora alokowanego `allocShared` (przeżywa poza
  ## GC-owaną stertą Nim, bezpieczny do trzymania po stronie wołającego aż
  ## do jawnego `ft_string_free`).
  let buf = cast[cstring](allocShared(s.len + 1))
  if s.len > 0:
    copyMem(buf, unsafeAddr s[0], s.len)
  cast[ptr UncheckedArray[char]](buf)[s.len] = '\0'
  buf

# --- Uchwyty ------------------------------------------------------------------

type
  FtStoreObj = object
    store: storeMod.Store
  FtStoreHandle* = ptr FtStoreObj

  FtManifestObj = object
    manifest: manifestMod.Manifest
  FtManifestHandle* = ptr FtManifestObj

proc ft_store_open*(root: cstring, outHandle: ptr FtStoreHandle): FtStatus
    {.exportc, dynlib, cdecl.} =
  ## Otwiera (lub inicjalizuje, jeśli puste) CAS pod `root`. Przy sukcesie
  ## `outHandle^` wskazuje na nowo zaalokowany uchwyt — zwolnij go
  ## `ft_store_close`, gdy skończysz.
  ftGuard:
    if root == nil or outHandle == nil:
      lastErrorMsg = "root/outHandle nie mogą być NULL"
      return ftErrInvalidArgument
    let s = storeMod.openStore($root)
    let h = cast[FtStoreHandle](allocShared0(sizeof(FtStoreObj)))
    h.store = s
    outHandle[] = h

proc ft_store_close*(handle: FtStoreHandle) {.exportc, dynlib, cdecl.} =
  if handle != nil:
    deallocShared(handle)

proc ft_store_has*(handle: FtStoreHandle, hashHex: cstring): cint
    {.exportc, dynlib, cdecl.} =
  ## Zwraca 1/0. Błędny hashHex (zła długość hex) traktowany jako "brak" (0),
  ## nie jako błąd — sprawdzenie istnienia z natury dopuszcza "nie wiem/nie ma".
  if handle == nil or hashHex == nil: return 0
  try:
    (if handle.store.has(hashFromHex($hashHex)): 1 else: 0)
  except CatchableError:
    0

proc ft_store_put*(handle: FtStoreHandle, data: ptr byte, dataLen: csize_t,
                    outHashHex: ptr cstring): FtStatus {.exportc, dynlib, cdecl.} =
  ## Zapisuje blok danych, zwraca jego hash jako hex string (owned —
  ## zwolnij `ft_string_free`). `data` może być NULL tylko gdy dataLen == 0.
  ftGuard:
    if handle == nil or outHashHex == nil:
      lastErrorMsg = "handle/outHashHex nie mogą być NULL"
      return ftErrInvalidArgument
    var buf: seq[byte]
    if dataLen.int > 0:
      if data == nil:
        lastErrorMsg = "data == NULL przy dataLen > 0"
        return ftErrInvalidArgument
      buf = newSeq[byte](dataLen.int)
      copyMem(addr buf[0], data, dataLen.int)
    let h = handle.store.put(buf)
    outHashHex[] = toOwnedCstring($h)

proc ft_store_get*(handle: FtStoreHandle, hashHex: cstring,
                    outData: ptr ptr byte, outLen: ptr csize_t): FtStatus
    {.exportc, dynlib, cdecl.} =
  ## Odczytuje blok po hashu. Bufor `outData^` alokowany `allocShared` —
  ## zwolnij `ft_bytes_free` (NIE `ft_string_free` — brak gwarancji NUL-terminacji).
  ftGuard:
    if handle == nil or hashHex == nil or outData == nil or outLen == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    let maybe = handle.store.get(hashFromHex($hashHex))
    if maybe.isNone:
      lastErrorMsg = "obiekt nie istnieje w store: " & $hashHex
      return ftErrNotFound
    let data = maybe.get
    let buf = cast[ptr byte](allocShared(max(data.len, 1)))
    if data.len > 0:
      copyMem(buf, unsafeAddr data[0], data.len)
    outData[] = buf
    outLen[] = csize_t(data.len)

proc ft_bytes_free*(p: ptr byte) {.exportc, dynlib, cdecl.} =
  if p != nil:
    deallocShared(p)

# --- Manifest -----------------------------------------------------------------

proc ft_manifest_build*(sourceDir: cstring, storeHandle: FtStoreHandle,
                         outHandle: ptr FtManifestHandle): FtStatus
    {.exportc, dynlib, cdecl.} =
  ## Buduje manifest z katalogu źródłowego (chunkuje pliki, zapisuje chunki
  ## do store'a wskazanego przez `storeHandle`, liczy root-hash). Odpowiednik
  ## `manifest.buildManifest` z reszty biblioteki Nim.
  ftGuard:
    if sourceDir == nil or storeHandle == nil or outHandle == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    let m = manifestMod.buildManifest($sourceDir, storeHandle.store)
    let h = cast[FtManifestHandle](allocShared0(sizeof(FtManifestObj)))
    h.manifest = m
    outHandle[] = h

proc ft_manifest_from_json*(jsonStr: cstring, outHandle: ptr FtManifestHandle): FtStatus
    {.exportc, dynlib, cdecl.} =
  ftGuard:
    if jsonStr == nil or outHandle == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    let m = manifestMod.manifestFromJson(parseJson($jsonStr))
    let h = cast[FtManifestHandle](allocShared0(sizeof(FtManifestObj)))
    h.manifest = m
    outHandle[] = h

proc ft_manifest_to_json*(handle: FtManifestHandle, outJson: ptr cstring): FtStatus
    {.exportc, dynlib, cdecl.} =
  ftGuard:
    if handle == nil or outJson == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    outJson[] = toOwnedCstring(pretty(manifestMod.toJson(handle.manifest)))

proc ft_manifest_root_hex*(handle: FtManifestHandle, outHashHex: ptr cstring): FtStatus
    {.exportc, dynlib, cdecl.} =
  ftGuard:
    if handle == nil or outHashHex == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    outHashHex[] = toOwnedCstring($handle.manifest.root)

proc ft_manifest_entry_count*(handle: FtManifestHandle): csize_t
    {.exportc, dynlib, cdecl.} =
  if handle == nil: return 0
  csize_t(handle.manifest.entries.len)

proc ft_manifest_format_version*(handle: FtManifestHandle): cint
    {.exportc, dynlib, cdecl.} =
  if handle == nil: return -1
  cint(handle.manifest.formatVersion)

proc ft_manifest_close*(handle: FtManifestHandle) {.exportc, dynlib, cdecl.} =
  if handle != nil:
    deallocShared(handle)

# --- GC -------------------------------------------------------------------

type FtGcResult* {.exportc: "FtGcResult", bycopy.} = object
  scannedObjects*: csize_t
  liveObjects*: csize_t
  deletedObjects*: csize_t
  freedBytes*: uint64

proc ft_gc_run*(ftRoot: cstring, dryRun: cint, outResult: ptr FtGcResult): FtStatus
    {.exportc, dynlib, cdecl.} =
  ftGuard:
    if ftRoot == nil or outResult == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    let r = gcMod.runGc($ftRoot, dryRun != 0)
    outResult[] = FtGcResult(
      scannedObjects: csize_t(r.scannedObjects),
      liveObjects: csize_t(r.liveObjects),
      deletedObjects: csize_t(r.deletedObjects),
      freedBytes: uint64(r.freedBytes))

# --- Pull / Deploy (pełny cykl, nie tylko Store/Manifest) --------------------
#
# Wcześniej C ABI (i przez to Rust) eksponowało tylko Store/Manifest/GC —
# `pull`/`deploy` istniały wyłącznie w CLI Nim. Poniższe dwie funkcje domykają
# tę lukę: `ft_pull_run` = pobranie+scalenie warstw OCI + zbudowanie manifestu,
# `ft_deploy_build_image` = zbudowanie obrazu composefs + policzenie dm-verity
# — dokładnie to, co robi `cli.cmdPull`/`cli.cmdDeploy`, tylko wywoływalne
# z Rust/C bez przechodzenia przez binarkę CLI.

proc ft_pull_run*(imageRef: cstring, cacheDir: cstring, workDir: cstring,
                   storeHandle: FtStoreHandle, outHandle: ptr FtManifestHandle): FtStatus
    {.exportc, dynlib, cdecl.} =
  ## Pełny `pull`: rozwiązuje referencję obrazu, pobiera/cache'uje warstwy
  ## OCI do `cacheDir`, rozpakowuje i scala je (whiteout/opaque whiteout) w
  ## `workDir`, buduje manifest FastTree (chunkowanie + zapis do store'a
  ## wskazanego przez `storeHandle`). Sieciowe błędy (DNS, TCP, HTTP 4xx/5xx)
  ## wracają jako `FT_ERR_IO` — sprawdź `ft_last_error()` po szczegóły.
  ftGuard:
    if imageRef == nil or cacheDir == nil or workDir == nil or
       storeHandle == nil or outHandle == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    let ref0 = ociMod.parseImageRef($imageRef)
    let resolved = ociMod.resolveImageLayers(ref0, $cacheDir)
    let mergedDir = ($workDir) / "merged"
    discard layersMod.materializeLayers(
      resolved.mapIt(it.path), ($workDir) / "layers", mergedDir)
    let m = manifestMod.buildManifest(mergedDir, storeHandle.store)
    let h = cast[FtManifestHandle](allocShared0(sizeof(FtManifestObj)))
    h.manifest = m
    outHandle[] = h

type FtDeployResult* {.exportc: "FtDeployResult", bycopy.} = object
  imageDigest*: cstring    ## owned — zwolnij ft_string_free
  verityRootHash*: cstring ## owned — zwolnij ft_string_free

proc ft_deploy_build_image*(manifestHandle: FtManifestHandle, storeHandle: FtStoreHandle,
                             materializedDir: cstring, outputImage: cstring,
                             outResult: ptr FtDeployResult): FtStatus
    {.exportc, dynlib, cdecl.} =
  ## Materializuje manifest do drzewa plików, buduje z niego obraz composefs
  ## i od razu liczy hash-tree dm-verity dla tego obrazu (patrz
  ## composefs.dmVerityFormat) — dokładnie sekwencja `cli.cmdDeploy` przed
  ## atomowym podmienieniem symlinka `current` (ten ostatni krok — sam
  ## atomic A/B swap na symlinku — zostaje po stronie wołającego, bo dotyczy
  ## układu katalogów specyficznego dla instalacji, nie samej biblioteki).
  ftGuard:
    if manifestHandle == nil or storeHandle == nil or materializedDir == nil or
       outputImage == nil or outResult == nil:
      lastErrorMsg = "argumenty nie mogą być NULL"
      return ftErrInvalidArgument
    let digest = composefsMod.buildImage(
      manifestHandle.manifest, storeHandle.store, $materializedDir, $outputImage)
    let vinfo = composefsMod.dmVerityFormat($outputImage)
    outResult[] = FtDeployResult(
      imageDigest: toOwnedCstring(digest),
      verityRootHash: toOwnedCstring(vinfo.rootHash))

proc ft_deploy_result_free*(r: ptr FtDeployResult) {.exportc, dynlib, cdecl.} =
  ## Zwalnia OBA pola `FtDeployResult` naraz — wygodniejsze niż dwa osobne
  ## `ft_string_free`, i mniej podatne na "zapomniałem jednego z dwóch".
  if r == nil: return
  ft_string_free(r.imageDigest)
  ft_string_free(r.verityRootHash)
  r.imageDigest = nil
  r.verityRootHash = nil

# --- Metadane biblioteki --------------------------------------------------

proc ft_format_version*(): cint {.exportc, dynlib, cdecl.} =
  cint(manifestMod.FastTreeFormatVersion)

proc ft_hash_algo*(): cstring {.exportc, dynlib, cdecl.} =
  ## Zwraca statyczny string (NIE wołaj ft_string_free na tym) — "blake3"
  ## lub "sha256-fallback", w zależności od tego, z czym zbudowano libfasttree.
  hashing.AlgoName.cstring
