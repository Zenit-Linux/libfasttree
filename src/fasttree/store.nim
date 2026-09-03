import std/[os, options, strutils]
import ./hashing

const StoreFormatVersion* = 1
  ## Wersja layoutu CAS na dysku. ZAMROŻONE od v1:
  ##   <root>/objects/<hex[0:2]>/<hex[2:]>   — jeden plik = jeden obiekt,
  ##   nazwa = pełny hash (hex) po odcięciu pierwszych dwóch znaków użytych
  ##   jako katalog-shard (dokładnie jak .git/objects). Zawartość pliku to
  ##   surowe bajty chunku, BEZ dodatkowego nagłówka/kompresji — kompresja
  ##   (zstd) i szyfrowanie, jeśli kiedyś dojdą, będą osobną, jawnie
  ##   oznaczoną wersją formatu (2+), żeby stare store'y dało się nadal czytać.
  ## Plik <root>/FORMAT zawiera samą liczbę wersji (ASCII, bez nowej linii
  ## wymagane) i jest zapisywany przy pierwszym `openStore` na pustym
  ## katalogu. Kolejne otwarcia weryfikują zgodność.

type
  StoreFormatError* = object of CatchableError

  Store* = object
    root*: string
    formatVersion*: int

proc openStore*(root: string): Store =
  createDir(root / "objects")
  let formatFile = root / "FORMAT"
  if fileExists(formatFile):
    let existing = readFile(formatFile).strip()
    let version = try: parseInt(existing) except ValueError: -1
    if version > StoreFormatVersion:
      raise newException(StoreFormatError,
        "Store pod '" & root & "' ma FORMAT=" & existing &
        ", ta wersja FastTree obsługuje do " & $StoreFormatVersion &
        ". Zaktualizuj fasttree.")
    if version < 1:
      raise newException(StoreFormatError,
        "Store pod '" & root & "' ma nierozpoznany plik FORMAT ('" & existing & "').")
    Store(root: root, formatVersion: version)
  else:
    writeFile(formatFile, $StoreFormatVersion)
    Store(root: root, formatVersion: StoreFormatVersion)

proc shardPath(s: Store, h: Hash): string =
  let hex = $h
  s.root / "objects" / hex[0..1] / hex[2..^1]

proc has*(s: Store, h: Hash): bool =
  fileExists(s.shardPath(h))

proc objectPath*(s: Store, h: Hash): string =
  ## Fizyczna ścieżka obiektu w CAS. Publiczne specjalnie dla `ioengine`
  ## (readBatch/writeBatch operują na ścieżkach plików, nie na abstrakcyjnym
  ## `Hash` — store.nim jest jedynym miejscem, które zna layout `objects/xx/yyyy`,
  ## ale composefs.buildImage potrzebuje surowych ścieżek do wsadowego I/O).
  s.shardPath(h)

proc put*(s: Store, data: openArray[byte]): Hash =
  ## Zapisuje blok, zwraca jego skrót. Zapis idempotentny — jeśli obiekt
  ## już istnieje (deduplikacja), nie jest nadpisywany.
  let h = hashBytes(data)
  let path = s.shardPath(h)
  if not fileExists(path):
    createDir(path.parentDir)
    let tmp = path & ".tmp." & $getCurrentProcessId()
    writeFile(tmp, cast[string](@data))
    moveFile(tmp, path)  # atomowa podmiana w obrębie tego samego FS
  h

proc get*(s: Store, h: Hash): Option[seq[byte]] =
  let path = s.shardPath(h)
  if not fileExists(path):
    return none(seq[byte])
  let content = readFile(path)
  var buf = newSeq[byte](content.len)
  if content.len > 0:
    copyMem(addr buf[0], unsafeAddr content[0], content.len)
  some(buf)

proc missing*(s: Store, hashes: openArray[Hash]): seq[Hash] =
  ## Zwraca listę skrótów, których store jeszcze nie ma lokalnie —
  ## dokładnie to `fasttree pull` wysyła jako zapytanie o brakujące warstwy/chunki.
  result = @[]
  for h in hashes:
    if not s.has(h):
      result.add h

proc listAll*(s: Store): seq[Hash] =
  ## Wylicza wszystkie obiekty aktualnie leżące w CAS — używane przez GC
  ## do policzenia zbioru "wszystko minus live-set = do usunięcia".
  result = @[]
  let objectsDir = s.root / "objects"
  if not dirExists(objectsDir): return
  for shardDir in walkDirs(objectsDir / "*"):
    let shard = shardDir.extractFilename
    if shard.len != 2: continue
    for f in walkFiles(shardDir / "*"):
      let rest = f.extractFilename
      if rest.len == 62 and not rest.contains('.'):  # pomija pliki *.tmp.*
        try:
          result.add hashFromHex(shard & rest)
        except AssertionDefect, ValueError:
          discard  # plik nie pasuje do formatu hasha — ignorujemy (nie nasz obiekt)

proc deleteObject*(s: Store, h: Hash): bool =
  ## Usuwa pojedynczy obiekt z CAS. Zwraca false, jeśli obiektu nie było
  ## (np. już usunięty w poprzednim, przerwanym przebiegu GC — idempotentne).
  let path = s.shardPath(h)
  if fileExists(path):
    removeFile(path)
    true
  else:
    false
