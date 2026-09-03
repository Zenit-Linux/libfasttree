import std/[os, json, strformat, times, strutils, sequtils]
import ./store
import ./manifest
import ./oci
import ./composefs
import ./layers
import ./gc
import ./overlay

proc rootDir(): string =
  getEnv("FASTTREE_ROOT", "/var/lib/fasttree")

proc ensureLayout() =
  for d in ["store", "deployments", "manifests", "layers-cache"]:
    createDir(rootDir() / d)

proc sanitizeTag(reference: string): string =
  ## Nazwa manifestu/wdrożenia na dysku — referencja OCI może zawierać
  ## znaki niebezpieczne jako nazwa pliku (np. "@sha256:..."), więc
  ## zamieniamy dwukropek na podkreślnik (tak samo jak dla nazw plików warstw).
  reference.replace(":", "_")

proc cmdPull*(imageRef: string) =
  ensureLayout()
  echo &"[fasttree] pull {imageRef}"
  let s = openStore(rootDir() / "store")
  let ref0 = parseImageRef(imageRef)
  let tag = sanitizeTag(ref0.reference)

  # 1. Pobierz (lub użyj z cache'u) wszystkie warstwy obrazu, w kolejności
  #    dół -> góra. Cache na poziomie blobów OCI jest niezależny od
  #    deduplikacji na poziomie chunków, która nastąpi w kroku 3.
  let resolved = resolveImageLayers(ref0, rootDir() / "layers-cache")
  let newlyDownloaded = resolved.filterIt(not it.wasCached).len
  echo &"[fasttree] {resolved.len} warstw łącznie, {newlyDownloaded} nowo pobranych " &
       &"({resolved.len - newlyDownloaded} już w cache)"

  # 2. Rozpakuj i scal warstwy (whiteouty OCI) do jednego materialnego drzewa.
  let workDir = getTempDir() / "fasttree-pull" / tag
  removeDir(workDir)  # czyste środowisko robocze na wypadek poprzedniego przerwanego pull
  let mergedDir = workDir / "merged"
  discard materializeLayers(resolved.mapIt(it.path), workDir / "layers", mergedDir)
  echo &"[fasttree] warstwy scalone w {mergedDir}"

  # 3. Zbuduj manifest FastTree: chunkowanie FastCDC + zapis chunków do CAS
  #    (deduplikacja automatyczna — identyczne chunki między wersjami/tagami
  #    trafiają do tego samego obiektu w store).
  let m = buildManifest(mergedDir, s)
  echo &"[fasttree] manifest zbudowany: root={m.root}, {m.entries.len} wpisów"

  let manifestPath = rootDir() / "manifests" / (tag & ".json")
  writeFile(manifestPath, pretty(toJson(m)))
  echo &"[fasttree] zapisano {manifestPath} — gotowe do 'fasttree deploy {tag}'"

  removeDir(workDir)  # posprzątaj drzewo robocze; chunki już bezpiecznie w store

proc cmdStatus*(showDiff: bool) =
  ensureLayout()
  let currentLink = rootDir() / "current"
  if not fileExists(currentLink) and not dirExists(currentLink):
    echo "[fasttree] brak aktywnego wdrożenia"
    return
  echo &"[fasttree] aktywne wdrożenie: {expandSymlink(currentLink)}"
  if showDiff:
    echo "[fasttree] --diff: porównanie root-hash bieżącego i poprzedniego manifestu"
    echo "[fasttree] TODO: wczytać manifests/<prev>.json i manifests/<current>.json, wywołać manifest.diff()"

proc cmdDeploy*(tag: string, atomic: bool) =
  ensureLayout()
  let s = openStore(rootDir() / "store")
  let manifestPath = rootDir() / "manifests" / (tag & ".json")
  if not fileExists(manifestPath):
    echo &"[fasttree] brak manifestu dla '{tag}' — najpierw 'fasttree pull'"
    return
  let m = manifestFromJson(parseFile(manifestPath))

  let deployDir = rootDir() / "deployments" / tag
  let image = deployDir & ".erofs"
  let digest = buildImage(m, s, materializedDir = deployDir & ".materialized", outputImage = image)
  writeFile(image & ".digest", digest)
  echo &"[fasttree] obraz composefs zbudowany, digest={digest}"

  # dm-verity: hash-tree obliczany od razu przy deploy, nie przy każdym
  # mount — root hash zapisany obok obrazu, gotowy do dmVerityOpen/Verify
  # bez ponownego liczenia całego drzewa przy każdym uruchomieniu.
  let vinfo = dmVerityFormat(image)
  writeFile(image & ".veritysum", vinfo.rootHash)
  echo &"[fasttree] dm-verity hash-tree obliczony, root={vinfo.rootHash}"

  let currentLink = rootDir() / "current"
  if atomic:
    # Atomowy A/B swap: nowy symlink budujemy pod tymczasową nazwą,
    # potem rename(2) na docelową — rename na tym samym FS jest atomowe,
    # więc bootloader/initramfs nigdy nie widzi połowicznego stanu.
    let tmpLink = currentLink & ".tmp"
    if fileExists(tmpLink) or symlinkExists(tmpLink): removeFile(tmpLink)
    createSymlink(image, tmpLink)
    moveFile(tmpLink, currentLink)
    echo &"[fasttree] wdrożono {tag} atomowo, current -> {image}"
  else:
    if fileExists(currentLink) or symlinkExists(currentLink): removeFile(currentLink)
    createSymlink(image, currentLink)
    echo &"[fasttree] wdrożono {tag}, current -> {image}"

  # CURRENT_TAG wskazuje GC (gc.nim), który manifest reprezentuje aktywny
  # deployment — bez tego GC nie wiedziałby, których chunków nie wolno ruszać.
  writeFile(rootDir() / "CURRENT_TAG", tag)

proc cmdGc*(dryRun: bool) =
  ensureLayout()
  echo &"[fasttree] gc{(if dryRun: \" --dry-run\" else: \"\")}: liczę live-set (CURRENT_TAG + pins.json)..."
  let res = runGc(rootDir(), dryRun)
  let verb = if dryRun: "zostałoby usuniętych" else: "usunięto"
  echo &"[fasttree] przeskanowano {res.scannedObjects} obiektów, {res.liveObjects} żywych, " &
       &"{verb} {res.deletedObjects} ({res.freedBytes} B)"

proc cmdPin*(tag: string, note: string) =
  ensureLayout()
  let pinsPath = rootDir() / "pins.json"
  var pins = if fileExists(pinsPath): parseFile(pinsPath) else: newJArray()
  pins.add %*{"tag": tag, "note": note, "pinnedAt": $now()}
  writeFile(pinsPath, pretty(pins))
  echo &"[fasttree] przypięto '{tag}': {note}"

proc cmdOverlayCreate*(name: string, ephemeral: bool) =
  ## Montuje CURRENT_TAG jako read-only lowerdir (composefs), potem dokłada
  ## overlay (trwały domyślnie — jak lokalne zmiany w /etc; --ephemeral dla
  ## efemerycznych/testowych). Dwa mounty na `name`: baza (readonly rootfs)
  ## + sam overlay, żeby lowerdir nie zależał od tego, czy ktoś inny akurat
  ## odmontował "current" pod nogami.
  ensureLayout()
  let currentTagFile = rootDir() / "CURRENT_TAG"
  if not fileExists(currentTagFile):
    echo "[fasttree] brak aktywnego wdrożenia (CURRENT_TAG) — najpierw 'fasttree deploy'"
    return
  let tag = readFile(currentTagFile).strip()
  let image = rootDir() / "deployments" / (tag & ".erofs")
  if not fileExists(image):
    echo &"[fasttree] brak obrazu dla aktywnego wdrożenia '{tag}' ({image})"
    return

  let baseMount = rootDir() / "overlay-base" / tag
  if not dirExists(baseMount) or not fileExists(baseMount / ".mounted"):
    mountImage(image, baseMount)
    writeFile(baseMount / ".mounted", "")
    echo &"[fasttree] zamontowano bazowy obraz '{tag}' (read-only) w {baseMount}"

  let mountpoint = rootDir() / "overlay-mounts" / name
  let ov =
    if ephemeral:
      newTmpOverlay(baseMount, mountpoint)
    else:
      newPersistentOverlay(baseMount, rootDir(), name, mountpoint)
  echo &"[fasttree] overlay '{name}' ({(if ephemeral: \"ulotny\" else: \"trwały\")}) zamontowany w {ov.mountpoint}"

proc cmdOverlayRemove*(name: string) =
  ensureLayout()
  let mountpoint = rootDir() / "overlay-mounts" / name
  let ephemeral = dirExists(mountpoint & ".tmpfs")
  let ov = Overlay(
    lowerdir: "", # nieużywane przez unmountOverlay
    upperdir: (if ephemeral: mountpoint & ".tmpfs" / "upper"
               else: rootDir() / "overlays" / name / "upper"),
    workdir: "",
    mountpoint: mountpoint,
    ephemeral: ephemeral,
    tmpfsMount: (if ephemeral: mountpoint & ".tmpfs" else: ""))
  unmountOverlay(ov)
  echo &"[fasttree] overlay '{name}' odmontowany" &
       (if ephemeral: " (dane ulotne — bezpowrotnie usunięte)" else: " (dane trwałe zachowane)")
