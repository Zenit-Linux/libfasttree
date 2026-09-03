import std/sequtils

type
  ChunkerConfig* = object
    minSize*: int
    avgSize*: int
    maxSize*: int

  Chunk* = object
    offset*: int
    data*: seq[byte]

const DefaultConfig* = ChunkerConfig(minSize: 4 * 1024, avgSize: 16 * 1024, maxSize: 64 * 1024)

# Tablica gear — 256 losowych 64-bitowych stałych używanych do rolling hash.
# W produkcyjnej wersji generowana raz i wbudowana jako stała; tu deterministyczny
# generator PRNG tylko po to, by moduł kompilował się samodzielnie.
proc buildGearTable(): array[256, uint64] =
  var seed: uint64 = 0x2545F4914F6CDD1Du64
  for i in 0 ..< 256:
    seed = seed xor (seed shl 13)
    seed = seed xor (seed shr 7)
    seed = seed xor (seed shl 17)
    result[i] = seed

const Gear = buildGearTable()

proc chunkBuffer*(data: openArray[byte], cfg: ChunkerConfig = DefaultConfig): seq[Chunk] =
  ## Dzieli bufor na chunki wg FastCDC. Deterministyczne dla identycznej
  ## zawartości i konfiguracji — kluczowe dla deduplikacji między wersjami.
  ##
  ## WAŻNE: `hash` NIGDY nie jest resetowany między chunkami — to jest sedno
  ## "content-defined": decyzja o cięciu w danym miejscu zależy tylko od
  ## treningu ostatnich kilkudziesięciu bajtów (naturalne "zapominanie" przez
  ## przepełnienie przy `shl`), NIE od odległości od poprzedniego cięcia.
  ## Reset hasha na starcie każdego chunku (błąd naprawiony w tej wersji)
  ## czynił granice zależnymi od pozycji — dokładnie to, czego FastCDC ma
  ## unikać względem sztywnego cięcia co N bajtów.
  result = @[]
  if data.len == 0:
    return
  var start = 0
  var i = 0
  var hash: uint64 = 0
  let maskHard = (1'u64 shl 15) - 1  ## trudniejszy próg (więcej bitów) — zniechęca do cięcia PONIŻEJ avgSize
  let maskEasy = (1'u64 shl 13) - 1  ## łatwiejszy próg (mniej bitów) — zachęca do cięcia POWYŻEJ avgSize, przed maxSize

  while i < data.len:
    let pos = i - start
    if pos >= cfg.maxSize:
      result.add Chunk(offset: start, data: data[start ..< i].toSeq)
      start = i
      continue

    hash = (hash shl 1) + Gear[data[i]]
    inc i

    if pos + 1 >= cfg.minSize:
      let threshold = if pos + 1 < cfg.avgSize: maskHard else: maskEasy
      if (hash and threshold) == 0:
        result.add Chunk(offset: start, data: data[start ..< i].toSeq)
        start = i
        hash = 0

  if start < data.len:
    result.add Chunk(offset: start, data: data[start ..< data.len].toSeq)
