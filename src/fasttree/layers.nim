import std/[os, osproc, strformat, strutils, tables]

type LayerError* = object of CatchableError

proc extractLayerTar*(layerTarPath, destDir: string) =
  ## `tar` z GNU tar auto-wykrywa gzip/zstd po zawartości niezależnie od
  ## rozszerzenia, więc jedno wywołanie obsługuje zarówno `.tar`, jak
  ## i `.tar.gz` (docker) czy warstwy OCI serwowane bez rozszerzenia.
  ## `--xattrs` prosi GNU tar o odtworzenie rozszerzonych atrybutów (np.
  ## `security.capability` na binarkach z setcap) — bez efektu, jeśli
  ## archiwum ich nie zawiera, więc bezpieczne do podania zawsze.
  createDir(destDir)
  let cmd = &"tar --xattrs --xattrs-include='*' -xf \"{layerTarPath}\" -C \"{destDir}\""
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(LayerError, &"rozpakowanie warstwy '{layerTarPath}' nie powiodło się: {output}")

const WhiteoutPrefix = ".wh."
const OpaqueWhiteoutName = ".wh..wh..opq"

proc isOpaqueWhiteout(name: string): bool = name == OpaqueWhiteoutName
proc isWhiteout(name: string): bool = name.startsWith(WhiteoutPrefix) and not isOpaqueWhiteout(name)
proc whiteoutTarget(name: string): string = name[WhiteoutPrefix.len .. ^1]

proc copyEntry(srcPath, destPath: string, seenInodes: var Table[(DeviceId, FileId), string]) =
  let info = getFileInfo(srcPath, followSymlink = false)
  case info.kind
  of pcDir:
    createDir(destPath)
  of pcLinkToFile, pcLinkToDir:
    if symlinkExists(destPath) or fileExists(destPath): removeFile(destPath)
    createSymlink(expandSymlink(srcPath), destPath)
  else:
    createDir(destPath.parentDir)
    if fileExists(destPath): removeFile(destPath)

    # Hardlinki: jeśli linkCount > 1, ten plik dzieli i-węzeł z innym wpisem
    # w TEJ SAMEJ warstwie (tar domyślnie zachowuje relacje hardlinków przy
    # rozpakowaniu). Odtwarzamy tę relację w destDir zamiast kopiować
    # zawartość N razy — ważne dla poprawności (dwie ścieżki, które MUSZĄ
    # zawsze mieć identyczną treść z definicji, nie przez przypadek).
    if info.linkCount > 1:
      let key = info.id
      if key in seenInodes:
        createHardlink(seenInodes[key], destPath)
        return
      else:
        seenInodes[key] = destPath
        # spada do zwykłego kopiowania niżej — to PIERWSZE wystąpienie tego i-węzła

    # `cp --preserve=mode,ownership,timestamps,xattr` zamiast ręcznego
    # read/write: zachowuje właściciela (uid/gid — istotne w obrazach
    # kontenerowych, gdzie pliki bywają nie-rootowe) i rozszerzone atrybuty
    # (np. `security.capability` na binarkach z setcap), czego Nimowe
    # `copyFileWithPermissions` (tylko bity uprawnień) nie robi.
    let (output, code) = execCmdEx(
      &"cp --preserve=mode,ownership,timestamps,xattr \"{srcPath}\" \"{destPath}\"")
    if code != 0:
      raise newException(LayerError, &"kopiowanie '{srcPath}' -> '{destPath}' nie powiodło się: {output}")

proc mergeLayerInto*(layerDir, destDir: string) =
  ## Nakłada JEDNĄ już rozpakowaną warstwę na materializowane drzewo docelowe.
  ## Wołane w kolejności warstw od najstarszej do najnowszej.

  # Krok 1: opaque whiteouts — wyczyść odziedziczoną zawartość katalogów,
  # które ta warstwa jawnie "resetuje", zanim skopiujemy jej własne pliki.
  for path in walkDirRec(layerDir, yieldFilter = {pcFile}):
    if path.extractFilename == OpaqueWhiteoutName:
      let relDir = path.parentDir.relativePath(layerDir)
      let targetDir = if relDir == ".": destDir else: destDir / relDir
      if dirExists(targetDir):
        removeDir(targetDir)
      createDir(targetDir)

  # Krok 2: skopiuj zwykłe pliki tej warstwy (pomijając same znaczniki whiteout).
  # `seenInodes` jest per-warstwa (nie per-cały-merge): hardlinki mają sens
  # tylko WEWNĄTRZ jednej warstwy tar — dwie różne warstwy nie dzielą i-węzłów
  # (każda to osobne rozpakowanie do osobnego katalogu roboczego).
  var seenInodes = initTable[(DeviceId, FileId), string]()
  for path in walkDirRec(layerDir, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
    let rel = path.relativePath(layerDir)
    if rel == ".": continue
    let name = path.extractFilename
    if isWhiteout(name) or isOpaqueWhiteout(name):
      continue
    copyEntry(path, destDir / rel, seenInodes)

  # Krok 3: whiteout pojedynczych plików — usuń odpowiedniki z destDir
  # (czyli z niższych warstw), PO skopiowaniu własnej zawartości warstwy.
  for path in walkDirRec(layerDir, yieldFilter = {pcFile}):
    let name = path.extractFilename
    if isWhiteout(name):
      let relDir = path.parentDir.relativePath(layerDir)
      let targetName = whiteoutTarget(name)
      let target = (if relDir == ".": destDir else: destDir / relDir) / targetName
      if dirExists(target): removeDir(target)
      elif fileExists(target) or symlinkExists(target): removeFile(target)

proc materializeLayers*(layerTarPaths: seq[string], workDir, destDir: string): string =
  ## Rozpakowuje i scala listę warstw (w podanej kolejności: dół -> góra)
  ## do `destDir`. Zwraca destDir dla wygody łańcuchowania.
  createDir(destDir)
  for i, layerTar in layerTarPaths:
    let layerDir = workDir / &"layer-{i}"
    extractLayerTar(layerTar, layerDir)
    mergeLayerInto(layerDir, destDir)
  destDir
