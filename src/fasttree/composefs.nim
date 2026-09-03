import std/[os, osproc, strformat, strutils, tables, asyncdispatch]
import ./manifest
import ./store
import ./ioengine

type ComposefsError* = object of CatchableError

const RequiredTools = {
  "mkcomposefs": "Usage: mkcomposefs",
  "mount.composefs": "usage: mount.composefs",
  "composefs-info": "usage: composefs-info",
}.toTable

proc requireTool(name: string) =
  ## Sam `findExe` nie wystarcza — plik o tej nazwie w PATH może być czymś
  ## innym (np. skryptem-atrapą). Uruchamiamy narzędzie bez argumentów i
  ## sprawdzamy w wyjściu charakterystyczny banner "Usage: ...". Żadne z
  ## tych narzędzi nie ma flagi `--version` (sprawdzone empirycznie), więc
  ## to jest jedyny niezawodny sposób potwierdzenia, że to WŁAŚCIWY binary,
  ## nie tylko że coś o tej nazwie istnieje.
  if findExe(name) == "":
    raise newException(ComposefsError,
      &"Brak narzędzia '{name}' w PATH. Zainstaluj pakiet composefs " &
      "(https://github.com/composefs/composefs — apt zwykle go nie ma, " &
      "trzeba zbudować z źródeł: meson setup build -Dfuse=disabled && ninja -C build).")
  let (output, _) = execCmdEx(name)
  let banner = RequiredTools.getOrDefault(name, "")
  if banner.len > 0 and banner notin output:
    raise newException(ComposefsError,
      &"'{name}' w PATH nie wygląda jak composefs (brak spodziewanego " &
      &"komunikatu '{banner}' w wyjściu) — sprawdź, czy PATH nie wskazuje " &
      "na inne narzędzie o tej samej nazwie.")

proc requireTool2(name: string) =
  ## Wariant requireTool bez wymogu konkretnego bannera (dla narzędzi spoza
  ## composefs — veritysetup, losetup — które mają własny, stabilny `--help`/
  ## kod wyjścia niepotrzebujący dodatkowej weryfikacji treści).
  if findExe(name) == "":
    raise newException(ComposefsError, &"Brak narzędzia '{name}' w PATH.")

proc buildImage*(m: Manifest, s: Store, materializedDir, outputImage: string): string =
  ## 1. Materializuje pliki z chunków store'a do tymczasowego drzewa katalogów
  ##    (bo mkcomposefs oczekuje realnego drzewa plików na wejściu) —
  ##    WSADOWO przez `ioengine` (io_uring gdy `-d:fasttreeIoUring`, inaczej
  ##    asyncdispatch): jeden `readBatch` na WSZYSTKIE unikalne chunki całego
  ##    manifestu, potem jeden `writeBatch` na wszystkie materializowane
  ##    pliki — zamiast N osobnych `store.get` jak w poprzedniej wersji.
  ## 2. Woła `mkcomposefs --print-digest materializedDir outputImage`.
  ## Zwraca digest obrazu (hex) — potrzebny do `mountVerified`/`dmVerityFormat`.
  requireTool("mkcomposefs")
  createDir(materializedDir)

  # Katalogi i symlinki materializujemy od razu (tanie, nie wymagają I/O na
  # danych) — tylko zawartość plików regularnych idzie przez wsadowy silnik.
  var fileEntries: seq[FileEntry] = @[]
  for e in m.entries:
    let full = materializedDir / e.path
    case e.mode
    of fmDirectory:
      createDir(full)
    of fmSymlink:
      createSymlink(e.linkTarget, full)
    of fmRegular, fmExecutable:
      createDir(full.parentDir)
      fileEntries.add e

  # Zbiór unikalnych hashy do odczytu — deduplikacja na tym samym poziomie
  # co store: jeśli 10 plików współdzieli ten sam chunk, czytamy go RAZ.
  var uniqueHashes: seq[Hash] = @[]
  var hashSeen = initTable[string, bool]()
  for e in fileEntries:
    for h in e.chunks:
      if $h notin hashSeen:
        hashSeen[$h] = true
        uniqueHashes.add h

  let eng = newIoEngine()
  defer: eng.close()

  var chunkPaths: seq[string] = @[]
  for h in uniqueHashes:
    let p = s.objectPath(h)
    if not fileExists(p):
      raise newException(ComposefsError, "brakujący chunk w store: " & $h)
    chunkPaths.add p

  let chunkContents = waitFor eng.readBatch(chunkPaths)
  var chunkByHash = initTable[string, seq[byte]]()
  for i, h in uniqueHashes:
    chunkByHash[$h] = chunkContents[i]

  # Złóż każdy plik z jego chunków (w pamięci) i przygotuj jeden wsadowy zapis.
  var writeJobs: seq[IoJob] = @[]
  for e in fileEntries:
    var buf: seq[byte] = @[]
    for h in e.chunks:
      buf.add chunkByHash[$h]
    writeJobs.add IoJob(path: materializedDir / e.path, data: buf)

  waitFor eng.writeBatch(writeJobs)

  for e in fileEntries:
    if e.mode == fmExecutable:
      let full = materializedDir / e.path
      setFilePermissions(full, getFilePermissions(full) + {fpUserExec, fpGroupExec, fpOthersExec})

  let (output, code) = execCmdEx(&"mkcomposefs --print-digest \"{materializedDir}\" \"{outputImage}\"")
  if code != 0:
    raise newException(ComposefsError, "mkcomposefs nie powiodło się: " & output)
  result = output.strip()
  if result.len != 64:
    raise newException(ComposefsError,
      "mkcomposefs --print-digest zwrócił nieoczekiwany format (" & $result.len &
      " znaków zamiast 64): " & result)

proc mountImage*(image, mountpoint: string, basedir = "") =
  ## `mount.composefs` zawsze wymaga składniowo `-o basedir=...`, nawet gdy
  ## zawartość jest w pełni inline w obrazie (jak w `buildImage` powyżej,
  ## bez `--digest-store`) — sprawdzone empirycznie, że wtedy sama treść
  ## katalogu basedir nie ma znaczenia, ale opcja musi być podana. Domyślnie
  ## używamy samego `image.parentDir` jako nieszkodliwej wartości.
  requireTool("mount.composefs")
  createDir(mountpoint)
  let bd = if basedir.len > 0: basedir else: image.parentDir
  let (output, code) = execCmdEx(&"mount.composefs -o basedir=\"{bd}\",ro \"{image}\" \"{mountpoint}\"")
  if code != 0:
    raise newException(ComposefsError, "montowanie composefs nie powiodło się: " & output)

proc mountVerified*(image, mountpoint, expectedDigest: string, basedir = "") =
  ## Montuje z wymuszeniem `-o digest=X` — jądro/composefs odmówi zamontowania,
  ## jeśli obliczony digest obrazu się nie zgadza. WYMAGA fs-verity włączonego
  ## na pliku `image` przez hosta (filesystem z cechą `verity`, np. ext4/btrfs
  ## sformatowane z `-O verity`, plus `fsverity enable image.cfs`) — bez tego
  ## composefs zgłosi "Image has no fs-verity" (zweryfikowane empirycznie
  ## podczas developmentu tego modułu). Jeśli Twój host tego nie wspiera,
  ## użyj zamiast tego `dmVerityFormat`/`dmVerityOpen` (dm-verity na poziomie
  ## device-mapper, niezależne od fs-verity plikowego).
  requireTool("mount.composefs")
  createDir(mountpoint)
  let bd = if basedir.len > 0: basedir else: image.parentDir
  let (output, code) = execCmdEx(
    &"mount.composefs -o basedir=\"{bd}\",digest={expectedDigest},ro \"{image}\" \"{mountpoint}\"")
  if code != 0:
    raise newException(ComposefsError,
      "montowanie z weryfikacją digestu nie powiodło się (być może host nie " &
      "ma włączonego fs-verity na tym systemie plików — patrz komentarz " &
      "mountVerified w composefs.nim): " & output)

# --- dm-verity (device-mapper) ----------------------------------------------
#
# Niezależna od fs-verity ścieżka integralności: `veritysetup format` liczy
# drzewo hashy (Merkle nad blokami pliku) do OSOBNEGO pliku, `veritysetup
# open` mapuje parę (dane, hash-tree) jako urządzenie /dev/mapper/NAZWA,
# które jądro weryfikuje blok-po-bloku PRZY KAŻDYM ODCZYCIE — to jest
# dosłowne dm-verity z opisu architektury. Wymaga załadowanego modułu
# jądra `dm_mod`/`dm-verity` i uprawnień do device-mapper (CAP_SYS_ADMIN) —
# niedostępne w niektórych środowiskach kontenerowych (np. sandboks bez
# dostępu do /dev/mapper), dlatego `dmVerityFormat`/`dmVerityVerify` (czysto
# plikowe, bez device-mapper) działają zawsze, a `dmVerityOpen` może zgłosić
# błąd środowiskowy, jeśli device-mapper jest niedostępny.

type DmVerityInfo* = object
  rootHash*: string
  hashTreePath*: string

proc dmVerityFormat*(dataPath: string): DmVerityInfo =
  ## Liczy hash-tree dla `dataPath` (zwykle obraz composefs z buildImage) do
  ## `dataPath & ".verity-hashtree"`. Zwraca root hash — to jest wartość,
  ## którą trzeba zapisać obok obrazu (np. w manifests/<tag>.json), żeby
  ## później zweryfikować/otworzyć urządzenie dm-verity.
  requireTool2("veritysetup")
  let hashTreePath = dataPath & ".verity-hashtree"
  if fileExists(hashTreePath): removeFile(hashTreePath)
  let (output, code) = execCmdEx(&"veritysetup format \"{dataPath}\" \"{hashTreePath}\"")
  if code != 0:
    raise newException(ComposefsError, "veritysetup format nie powiodło się: " & output)
  var rootHash = ""
  for line in output.splitLines:
    if line.startsWith("Root hash:"):
      rootHash = line.split(':', 1)[1].strip()
  if rootHash.len != 64:
    raise newException(ComposefsError,
      "nie udało się sparsować 'Root hash:' z wyjścia veritysetup format:\n" & output)
  DmVerityInfo(rootHash: rootHash, hashTreePath: hashTreePath)

proc dmVerityVerify*(dataPath, hashTreePath, rootHash: string): bool =
  ## Weryfikacja BEZ device-mapper — czysto plikowe porównanie hash-tree
  ## względem danych. Wolniejsze niż kernel-level dm-verity (jednorazowy
  ## przebieg całego pliku zamiast weryfikacji per-blok przy odczycie), ale
  ## działa wszędzie (nie wymaga /dev/mapper) — dobre jako szybki pre-check
  ## przed próbą `dmVerityOpen`, albo jedyna opcja w środowiskach bez
  ## dostępu do device-mapper.
  requireTool2("veritysetup")
  let (_, code) = execCmdEx(&"veritysetup verify \"{dataPath}\" \"{hashTreePath}\" \"{rootHash}\"")
  code == 0

proc dmVerityOpen*(dataPath, hashTreePath, rootHash, mapperName: string): string =
  ## Tworzy /dev/mapper/<mapperName> zweryfikowany kernelowo blok-po-bloku.
  ## WYMAGA: załadowanego modułu jądra dm_mod oraz dostępu do device-mapper
  ## (poza zasięgiem niektórych kontenerów/sandboksów — jeśli zobaczysz
  ## "Cannot initialize device-mapper", Twoje środowisko tego nie wspiera;
  ## użyj `dmVerityVerify` jako alternatywy). Dane i hash-tree są mapowane
  ## przez pętle (`losetup`), bo `veritysetup open` oczekuje urządzeń blokowych.
  requireTool2("veritysetup")
  requireTool2("losetup")
  let (dataLoopRaw, c1) = execCmdEx(&"losetup -f --show \"{dataPath}\"")
  if c1 != 0: raise newException(ComposefsError, "losetup (dane) nie powiodło się: " & dataLoopRaw)
  let dataLoop = dataLoopRaw.strip()

  let (hashLoopRaw, c2) = execCmdEx(&"losetup -f --show \"{hashTreePath}\"")
  if c2 != 0:
    discard execCmdEx(&"losetup -d \"{dataLoop}\"")
    raise newException(ComposefsError, "losetup (hash-tree) nie powiodło się: " & hashLoopRaw)
  let hashLoop = hashLoopRaw.strip()

  let (output, code) = execCmdEx(&"veritysetup open \"{dataLoop}\" \"{mapperName}\" \"{hashLoop}\" \"{rootHash}\"")
  if code != 0:
    discard execCmdEx(&"losetup -d \"{dataLoop}\"")
    discard execCmdEx(&"losetup -d \"{hashLoop}\"")
    raise newException(ComposefsError,
      "veritysetup open nie powiodło się (być może brak device-mapper w tym " &
      "środowisku — patrz komentarz dmVerityOpen w composefs.nim): " & output)
  "/dev/mapper/" & mapperName

proc dmVerityClose*(mapperName: string) =
  discard execCmdEx(&"veritysetup close \"{mapperName}\"")
