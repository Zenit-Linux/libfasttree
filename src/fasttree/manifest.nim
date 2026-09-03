import std/[os, algorithm, json, options, tables, sets]
import ./hashing
import ./chunker
import ./store

export hashing  # Hash, `$`, hashFromHex itd. — część publicznego API manifestu

const FastTreeFormatVersion* = 1
  ## Wersja formatu manifestu na dysku. ZASADA: to pole rośnie WYŁĄCZNIE przy
  ## zmianie niekompatybilnej wstecz (np. inny layout pól, inny sposób
  ## liczenia root-hash). Dodanie nowego opcjonalnego pola JSON nie wymaga
  ## bumpa. Każdy czytelnik (Nim, przyszły Rust wrapper) MUSI odrzucić
  ## manifest z formatVersion > FastTreeFormatVersion zamiast zgadywać.
  ##
  ## Historia:
  ##   1 (obecna) — pierwszy zamrożony format: entries[] posortowane po path,
  ##     root = hashChildren(entryHash(e) for e in entries), entryHash(e) =
  ##     hashChildren([hash(path|mode), chunks...]). chunker{min,avg,max}
  ##     oraz hashAlgo zapisane informacyjnie (nie wchodzą do liczenia root-hash).

type
  FileMode* = enum
    fmRegular, fmExecutable, fmSymlink, fmDirectory

  FileEntry* = object
    path*: string             # ścieżka względna w drzewie
    mode*: FileMode
    size*: int64
    chunks*: seq[Hash]        # puste dla katalogów/symlinków
    linkTarget*: string       # tylko dla symlinków

  ChunkerInfo* = object
    ## Kopia parametrów chunkera użytych przy budowie manifestu — zapisana
    ## informacyjnie. Nie wpływa na root-hash (root liczony z już powstałych
    ## chunków), ale bez tego nie da się odtworzyć/zweryfikować, dlaczego
    ## dwa manifesty tej samej zawartości mają różne granice chunków.
    minSize*, avgSize*, maxSize*: int

  Manifest* = object
    formatVersion*: int             # patrz FastTreeFormatVersion powyżej
    hashAlgo*: string               # "blake3" | "sha256-fallback" — patrz hashing.AlgoName
    chunker*: ChunkerInfo
    root*: Hash                     # hash calego drzewa (dla szybkiego diff)
    entries*: seq[FileEntry]        # posortowane po path

proc modeToStr(m: FileMode): string =
  case m
  of fmRegular: "regular"
  of fmExecutable: "executable"
  of fmSymlink: "symlink"
  of fmDirectory: "directory"

proc strToMode(s: string): FileMode =
  case s
  of "regular": fmRegular
  of "executable": fmExecutable
  of "symlink": fmSymlink
  of "directory": fmDirectory
  else: raise newException(ValueError, "nieznany tryb pliku: " & s)

proc entryHash(e: FileEntry): Hash =
  ## Hash pojedynczego wpisu = hash(path | mode | chunks...) — pozwala
  ## wykryć zmianę metadanych nawet bez zmiany zawartości.
  var parts: seq[Hash] = @[hashBytes(cast[seq[byte]](e.path & "|" & modeToStr(e.mode)))]
  parts.add e.chunks
  hashChildren(parts)

proc buildManifest*(sourceDir: string, s: Store, cfg: ChunkerConfig = DefaultConfig): Manifest =
  ## Przechodzi po katalogu źródłowym, dzieli pliki na chunki (FastCDC),
  ## zapisuje chunki do store'a (dedup automatyczny — identyczne chunki
  ## między plikami/wersjami trafiają do tego samego obiektu) i buduje manifest.
  var entries: seq[FileEntry] = @[]

  for path in walkDirRec(sourceDir, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
    let rel = path.relativePath(sourceDir)
    if rel == ".": continue
    let info = getFileInfo(path, followSymlink = false)
    case info.kind
    of pcDir:
      entries.add FileEntry(path: rel, mode: fmDirectory, size: 0)
    of pcLinkToFile, pcLinkToDir:
      entries.add FileEntry(path: rel, mode: fmSymlink, linkTarget: expandSymlink(path))
    else:
      let content = readFile(path)
      var buf = newSeq[byte](content.len)
      if content.len > 0:
        copyMem(addr buf[0], unsafeAddr content[0], content.len)
      let chunks = chunkBuffer(buf, cfg)
      var hashes: seq[Hash] = @[]
      for c in chunks:
        hashes.add s.put(c.data)
      let isExec = (info.permissions.contains(fpUserExec))
      entries.add FileEntry(
        path: rel,
        mode: (if isExec: fmExecutable else: fmRegular),
        size: info.size,
        chunks: hashes)

  entries.sort(proc(a, b: FileEntry): int = cmp(a.path, b.path))

  var entryHashes: seq[Hash] = @[]
  for e in entries:
    entryHashes.add entryHash(e)

  Manifest(
    formatVersion: FastTreeFormatVersion,
    hashAlgo: AlgoName,
    chunker: ChunkerInfo(minSize: cfg.minSize, avgSize: cfg.avgSize, maxSize: cfg.maxSize),
    root: hashChildren(entryHashes),
    entries: entries)

proc toJson*(m: Manifest): JsonNode =
  result = %*{
    "formatVersion": m.formatVersion,
    "hashAlgo": m.hashAlgo,
    "chunker": {"minSize": m.chunker.minSize, "avgSize": m.chunker.avgSize, "maxSize": m.chunker.maxSize},
    "root": $m.root,
    "entries": newJArray()
  }
  for e in m.entries:
    var chunksJson = newJArray()
    for c in e.chunks: chunksJson.add %($c)
    result["entries"].add %*{
      "path": e.path,
      "mode": modeToStr(e.mode),
      "size": e.size,
      "chunks": chunksJson,
      "linkTarget": e.linkTarget
    }

type ManifestFormatError* = object of CatchableError

proc manifestFromJson*(j: JsonNode): Manifest =
  ## Reguła kompatybilności: manifest z formatVersion nieznanym tej wersji
  ## FastTree (nowszym niż FastTreeFormatVersion) jest odrzucany jawnym
  ## błędem, zamiast próby "zgadywania" pól, które mogły zmienić znaczenie.
  ## Brak pola formatVersion (bardzo stare/obce pliki) traktujemy jako 0.
  let formatVersion = j{"formatVersion"}.getInt(0)
  if formatVersion > FastTreeFormatVersion:
    raise newException(ManifestFormatError,
      "Manifest ma formatVersion=" & $formatVersion &
      ", ta wersja FastTree obsługuje do " & $FastTreeFormatVersion &
      ". Zaktualizuj fasttree.")
  if formatVersion == 0:
    raise newException(ManifestFormatError,
      "Manifest bez pola 'formatVersion' — nierozpoznany/przedwersyjny format.")

  let hashAlgo = j{"hashAlgo"}.getStr("")
  if hashAlgo.len > 0 and hashAlgo != AlgoName:
    # Nie jest to twardy błąd (root-hash i tak się nie zgodzi przy realnym
    # mismatchu treści), ale ostrzeżenie ratuje przed cichym pomieszaniem
    # repozytoriów zbudowanych blake3 vs fallback sha256.
    stderr.writeLine("[fasttree] UWAGA: manifest policzony algorytmem '" &
      hashAlgo & "', bieżąca kompilacja używa '" & AlgoName & "'.")

  var chunkerInfo = ChunkerInfo()
  if j.hasKey("chunker"):
    let jc = j["chunker"]
    chunkerInfo = ChunkerInfo(
      minSize: jc{"minSize"}.getInt(DefaultConfig.minSize),
      avgSize: jc{"avgSize"}.getInt(DefaultConfig.avgSize),
      maxSize: jc{"maxSize"}.getInt(DefaultConfig.maxSize))

  var entries: seq[FileEntry] = @[]
  for je in j["entries"]:
    var chunks: seq[Hash] = @[]
    for jc in je["chunks"]:
      chunks.add hashFromHex(jc.getStr)
    entries.add FileEntry(
      path: je["path"].getStr,
      mode: strToMode(je["mode"].getStr),
      size: je["size"].getBiggestInt,
      chunks: chunks,
      linkTarget: je{"linkTarget"}.getStr(""))
  Manifest(
    formatVersion: formatVersion,
    hashAlgo: (if hashAlgo.len > 0: hashAlgo else: AlgoName),
    chunker: chunkerInfo,
    root: hashFromHex(j["root"].getStr),
    entries: entries)

type
  DiffKind* = enum dkAdded, dkRemoved, dkModified
  DiffEntry* = object
    kind*: DiffKind
    path*: string
    oldChunks*, newChunks*: int   # do statystyki: ile chunków zmienionych
    reusedChunks*: int            # ile chunków wspólnych ze starą wersją (dedup w akcji)

proc diff*(old, new: Manifest): seq[DiffEntry] =
  ## Porównanie na poziomie plików i chunków — to jest "łatwy wywód
  ## różnicowy" z Twojego opisu: zamiast diffować bajty, porównujemy
  ## listy skrótów, więc koszt jest O(liczba wpisów), nie O(rozmiar danych).
  result = @[]
  var oldByPath = initTable[string, FileEntry]()
  for e in old.entries: oldByPath[e.path] = e
  var seen = initHashSet[string]()

  for ne in new.entries:
    seen.incl ne.path
    if ne.path notin oldByPath:
      result.add DiffEntry(kind: dkAdded, path: ne.path, newChunks: ne.chunks.len)
    else:
      let oe = oldByPath[ne.path]
      if entryHash(oe) != entryHash(ne):
        var oldSet = initHashSet[string]()
        for c in oe.chunks: oldSet.incl $c
        var reused = 0
        for c in ne.chunks:
          if $c in oldSet: inc reused
        result.add DiffEntry(kind: dkModified, path: ne.path,
                              oldChunks: oe.chunks.len, newChunks: ne.chunks.len,
                              reusedChunks: reused)

  for oe in old.entries:
    if oe.path notin seen:
      result.add DiffEntry(kind: dkRemoved, path: oe.path, oldChunks: oe.chunks.len)
