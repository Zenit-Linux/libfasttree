import std/[os, json, strutils, sets, options]
import ./store
import ./manifest

type
  GcResult* = object
    scannedObjects*: int
    liveObjects*: int
    deletedObjects*: int
    freedBytes*: int64

proc liveTags*(root: string): seq[string] =
  ## Tagi, których manifesty NIE mogą zostać zebrane przez GC.
  result = @[]
  let currentTagFile = root / "CURRENT_TAG"
  if fileExists(currentTagFile):
    let t = readFile(currentTagFile).strip()
    if t.len > 0: result.add t

  let pinsPath = root / "pins.json"
  if fileExists(pinsPath):
    for p in parseFile(pinsPath):
      let t = p["tag"].getStr
      if t notin result: result.add t

proc liveChunkHashes*(root: string): HashSet[string] =
  ## Zbiór hex-hashy wszystkich chunków referencowanych przez żywe manifesty.
  ## Brakujący plik manifestu dla żywego tagu jest CELOWO błędem krytycznym
  ## (nie cichym pominięciem) — inaczej GC mógłby usunąć dane wciąż używane
  ## przez deployment, którego manifest akurat zniknął z dysku.
  result = initHashSet[string]()
  for tag in liveTags(root):
    let mpath = root / "manifests" / (tag & ".json")
    if not fileExists(mpath):
      raise newException(IOError,
        "GC: brak manifestu dla żywego tagu '" & tag & "' (" & mpath &
        "). Przerywam GC — nie mogę bezpiecznie policzyć live-setu.")
    let m = manifestFromJson(parseFile(mpath))
    for e in m.entries:
      for c in e.chunks:
        result.incl $c

proc runGc*(root: string, dryRun = false): GcResult =
  let s = openStore(root / "store")
  let live = liveChunkHashes(root)
  result.liveObjects = live.len

  for h in s.listAll():
    inc result.scannedObjects
    if $h notin live:
      let data = s.get(h)
      if data.isSome:
        result.freedBytes += data.get.len
      if not dryRun:
        discard s.deleteObject(h)
      inc result.deletedObjects
