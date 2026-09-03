import std/[unittest, random, sets]
import fasttree/chunker

proc randomBytes(n: int, seed: int64): seq[byte] =
  ## UWAGA: dane testowe MUSZĄ mieć realistyczną entropię. Prosty generator
  ## okresowy typu `byte(i*11+5 mod 256)` ma okres dokładnie 256 — po tylu
  ## bajtach hash "zapominający" (patrz komentarz w chunker.nim) ma tylko
  ## ~256 unikalnych stanów, co sztucznie i drastycznie zaniża trafienia
  ## progu FastCDC i psuje test niezwiązany z żadnym realnym bugiem chunkera
  ## (złapane podczas developmentu — patrz historia tego pliku).
  result = newSeq[byte](n)
  var rng = initRand(seed)
  for i in 0 ..< n:
    result[i] = byte(rng.rand(255))

suite "chunker (FastCDC)":
  test "pusty bufor daje zero chunkow":
    check chunkBuffer(newSeq[byte](0)).len == 0

  test "maly bufor (ponizej minSize) to jeden chunk":
    let data = randomBytes(100, 1)
    let chunks = chunkBuffer(data)
    check chunks.len == 1
    check chunks[0].data.len == 100

  test "chunki skladaja sie z powrotem na oryginalne dane (bez dziur, bez nakladania)":
    let data = randomBytes(500_000, 2)
    let chunks = chunkBuffer(data)
    check chunks.len > 1

    var reconstructed = newSeq[byte]()
    for c in chunks: reconstructed.add c.data
    check reconstructed == data

  test "kazdy chunk miesci sie w [minSize, maxSize] poza ewentualnie ostatnim":
    let data = randomBytes(300_000, 3)
    let cfg = ChunkerConfig(minSize: 2048, avgSize: 8192, maxSize: 32768)
    let chunks = chunkBuffer(data, cfg)
    check chunks.len > 1
    for i, c in chunks:
      if i < chunks.len - 1:
        check c.data.len >= cfg.minSize
      check c.data.len <= cfg.maxSize

  test "deterministyczny: te same dane -> te same granice chunkow":
    let data = randomBytes(200_000, 4)
    let chunks1 = chunkBuffer(data)
    let chunks2 = chunkBuffer(data)
    check chunks1.len == chunks2.len
    for i in 0 ..< chunks1.len:
      check chunks1[i].data == chunks2[i].data

  test "srednia dlugosc chunku jest w rozsadnym zakresie wokol avgSize":
    let data = randomBytes(2_000_000, 5)
    let chunks = chunkBuffer(data)
    let avgActual = data.len div chunks.len
    # nie oczekujemy idealnego trafienia w DefaultConfig.avgSize (16384),
    # ale rzad wielkosci powinien sie zgadzac (nie 100x za male/za duze)
    check avgActual > DefaultConfig.avgSize div 8
    check avgActual < DefaultConfig.avgSize * 8

  test "content-defined: wstawka na poczatku nie przesuwa WSZYSTKICH nastepnych granic":
    ## Sedno FastCDC (w odroznieniu od ciecia co N bajtow): wstawka w jednym
    ## miejscu powinna zmienic tylko chunk(i) w jej okolicy — reszta pliku,
    ## dostatecznie daleko od edycji, powinna dac IDENTYCZNE chunki.
    let original = randomBytes(400_000, 6)
    var modified = randomBytes(5, 999)  # 5 "obcych" bajtow wstawki
    modified.add original

    let chunksOrig = chunkBuffer(original)
    let chunksMod = chunkBuffer(modified)

    var origSet = initHashSet[string]()
    for c in chunksOrig: origSet.incl cast[string](c.data)

    var sharedCount = 0
    for c in chunksMod:
      if cast[string](c.data) in origSet: inc sharedCount

    # Przy sztywnym cieciu co N bajtow sharedCount bylby ~0 (wszystko przesuniete
    # o 5 bajtow). FastCDC powinien odzyskac wiekszosc chunkow spoza okolicy edycji.
    check sharedCount > (chunksOrig.len div 2)
