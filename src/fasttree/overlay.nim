import std/[os, osproc, strformat, strutils]

type OverlayError* = object of CatchableError

type Overlay* = object
  lowerdir*: string
  upperdir*: string
  workdir*: string
  mountpoint*: string
  ephemeral*: bool
    ## true = upperdir/workdir żyją w tmpfs zamontowanym specjalnie dla tego
    ## overlaya (odmontowanie tmpfs = trwałe zniknięcie zmian);
    ## false = upperdir/workdir to zwykłe katalogi na dysku, przeżywają odmontowanie.
  tmpfsMount*: string
    ## puste dla trybu trwałego; dla ulotnego — punkt montowania tmpfs,
    ## który trzeba odmontować PO odmontowaniu samego overlaya (odwrotna
    ## kolejność niż montowanie).

proc requireOverlayfs() =
  ## OverlayFS jest wbudowane w większość jąder Linux (CONFIG_OVERLAY_FS),
  ## ale nie wszędzie — sprawdzamy przez /proc/filesystems zamiast na ślepo
  ## próbować mount i mylić "brak wsparcia" z innym błędem (złe ścieżki itp.).
  if not fileExists("/proc/filesystems"):
    return  # nie na Linuksie / brak /proc — zostawiamy błąd faktycznemu mount
  let content = readFile("/proc/filesystems")
  if "overlay" notin content:
    raise newException(OverlayError,
      "Jądro nie zgłasza wsparcia dla overlay w /proc/filesystems — " &
      "OverlayFS (CONFIG_OVERLAY_FS) wymagane dla `fasttree overlay`.")

proc doMountOverlay(lowerdir, upperdir, workdir, mountpoint: string) =
  createDir(mountpoint)
  let opts = &"lowerdir={lowerdir},upperdir={upperdir},workdir={workdir}"
  let (output, code) = execCmdEx(&"mount -t overlay overlay -o {opts} \"{mountpoint}\"")
  if code != 0:
    raise newException(OverlayError, "mount -t overlay nie powiodło się: " & output)

proc newPersistentOverlay*(lowerdir, ftRoot, name, mountpoint: string): Overlay =
  ## Trwały overlay: upperdir/workdir pod `<ftRoot>/overlays/<name>/`.
  ## Wołający jest odpowiedzialny za `unmountOverlay` przy zamykaniu, ale
  ## same pliki w upperdir PRZEŻYWAJĄ odmontowanie (w przeciwieństwie do
  ## `newTmpOverlay`) — to jest cecha, nie bug: `fasttree overlay create`
  ## bez `--ephemeral` ma dawać coś jak `/etc` w OSTree.
  requireOverlayfs()
  let base = ftRoot / "overlays" / name
  let upperdir = base / "upper"
  let workdir = base / "work"
  createDir(upperdir)
  createDir(workdir)
  doMountOverlay(lowerdir, upperdir, workdir, mountpoint)
  Overlay(lowerdir: lowerdir, upperdir: upperdir, workdir: workdir,
          mountpoint: mountpoint, ephemeral: false, tmpfsMount: "")

proc newTmpOverlay*(lowerdir, mountpoint: string, sizeMb = 512): Overlay =
  ## Ulotny overlay: upperdir/workdir w świeżo zamontowanym tmpfs pod
  ## `mountpoint & ".tmpfs"`. Cały stan znika, gdy `unmountOverlay` odmontuje
  ## tmpfs (albo po restarcie, jeśli proces się nie posprząta — tmpfs i tak
  ## nie przeżywa reboota).
  requireOverlayfs()
  let tmpfsMount = mountpoint & ".tmpfs"
  createDir(tmpfsMount)
  let (mtOut, mtCode) = execCmdEx(&"mount -t tmpfs -o size={sizeMb}m tmpfs \"{tmpfsMount}\"")
  if mtCode != 0:
    raise newException(OverlayError, "mount tmpfs (dla ulotnego upperdir) nie powiodło się: " & mtOut)

  let upperdir = tmpfsMount / "upper"
  let workdir = tmpfsMount / "work"
  createDir(upperdir)
  createDir(workdir)
  try:
    doMountOverlay(lowerdir, upperdir, workdir, mountpoint)
  except OverlayError:
    discard execCmdEx(&"umount \"{tmpfsMount}\"")
    raise
  Overlay(lowerdir: lowerdir, upperdir: upperdir, workdir: workdir,
          mountpoint: mountpoint, ephemeral: true, tmpfsMount: tmpfsMount)

proc unmountOverlay*(ov: Overlay) =
  ## Kolejność MA znaczenie dla trybu ulotnego: najpierw odmontuj sam
  ## overlay (który ma upperdir/workdir WEWNĄTRZ tmpfs), dopiero potem
  ## odmontuj tmpfs — w odwrotnej kolejności jądro odmówi (busy).
  let (out1, c1) = execCmdEx(&"umount \"{ov.mountpoint}\"")
  if c1 != 0:
    raise newException(OverlayError, "umount overlay nie powiodło się: " & out1)
  if ov.ephemeral and ov.tmpfsMount.len > 0:
    let (out2, c2) = execCmdEx(&"umount \"{ov.tmpfsMount}\"")
    if c2 != 0:
      raise newException(OverlayError, "umount tmpfs (upperdir ulotny) nie powiodło się: " & out2)

proc listChanges*(ov: Overlay): seq[string] =
  ## Lista ścieżek (względnych) zmienionych względem `lowerdir` — czyli
  ## zawartość `upperdir`. OverlayFS oznacza usunięte pliki "whiteoutami"
  ## (character device 0:0) i katalogi przesłonięte "opaque" xattr-em
  ## `trusted.overlay.opaque` — tu nie rozróżniamy tych przypadków od
  ## zwykłych nowych plików (wystarczy do przeglądu "co się zmieniło",
  ## niekoniecznie do precyzyjnego diff jak manifest.diff() dla FastTree).
  result = @[]
  if not dirExists(ov.upperdir): return
  for path in walkDirRec(ov.upperdir):
    result.add path.relativePath(ov.upperdir)
