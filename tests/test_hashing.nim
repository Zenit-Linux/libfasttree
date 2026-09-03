import std/[unittest, strutils]
import fasttree/hashing

suite "hashing":
  test "Hash round-trip przez hex ($ <-> hashFromHex)":
    let h = hashBytes(cast[seq[byte]]("dowolna tresc do zhashowania"))
    let hex = $h
    check hex.len == 64
    check hashFromHex(hex) == h

  test "hashFromHex odrzuca zla dlugosc (ValueError, NIE Defect/crash)":
    ## Krytyczne dla granicy FFI (capi.nim) — patrz komentarz w hashing.nim.
    expect ValueError:
      discard hashFromHex("za_krotki")
    expect ValueError:
      discard hashFromHex("a".repeat(63))
    expect ValueError:
      discard hashFromHex("a".repeat(65))

  test "hashBytes deterministyczny i wrazliwy na kazda zmiane":
    let a = hashBytes(cast[seq[byte]]("abc"))
    let b = hashBytes(cast[seq[byte]]("abc"))
    let c = hashBytes(cast[seq[byte]]("abd"))
    check a == b
    check a != c

  test "hashChildren rozni sie dla roznej kolejnosci dzieci (kolejnosc ma znaczenie)":
    let h1 = hashBytes(cast[seq[byte]]("x"))
    let h2 = hashBytes(cast[seq[byte]]("y"))
    check hashChildren([h1, h2]) != hashChildren([h2, h1])

  test "AlgoName zgodny z aktywnym backendem":
    when UsingBlake3:
      check AlgoName == "blake3"
    else:
      check AlgoName == "sha256-fallback"

  when UsingBlake3:
    test "wektory referencyjne BLAKE3 (policzone oficjalnym example.c z BLAKE3-team/BLAKE3)":
      check $hashBytes(cast[seq[byte]]("")) ==
        "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
      check $hashBytes(cast[seq[byte]]("abc")) ==
        "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"

      var pattern = newSeq[byte](1024)
      for i in 0 ..< 1024: pattern[i] = byte(i mod 251)
      check $hashBytes(pattern) ==
        "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"

    test "update() wielokrotny == jedno wywolanie hashBytes na calosci":
      var h = initHasher()
      h.update(cast[seq[byte]]("ab"))
      h.update(cast[seq[byte]]("c"))
      check h.finalize() == hashBytes(cast[seq[byte]]("abc"))
