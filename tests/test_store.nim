import std/[unittest, os, options]
import fasttree/store
import fasttree/hashing

proc tmpDir(name: string): string =
  result = getTempDir() / "fasttree-test-store-" & name & "-" & $getCurrentProcessId()
  removeDir(result)

suite "store (CAS)":
  test "put/get/has round-trip":
    let dir = tmpDir("roundtrip")
    defer: removeDir(dir)
    let s = openStore(dir)
    let h = s.put(cast[seq[byte]]("zawartosc testowa"))
    check s.has(h)
    let got = s.get(h)
    check got.isSome
    check cast[string](got.get) == "zawartosc testowa"

  test "get nieistniejacego obiektu zwraca none":
    let dir = tmpDir("missing")
    defer: removeDir(dir)
    let s = openStore(dir)
    let fakeHash = hashBytes(cast[seq[byte]]("cos czego nie zapisano"))
    check s.get(fakeHash).isNone
    check not s.has(fakeHash)

  test "put jest idempotentny (deduplikacja) — dwa put tych samych danych daja ten sam hash":
    let dir = tmpDir("dedup")
    defer: removeDir(dir)
    let s = openStore(dir)
    let h1 = s.put(cast[seq[byte]]("identyczna tresc"))
    let h2 = s.put(cast[seq[byte]]("identyczna tresc"))
    check h1 == h2

  test "missing zwraca tylko brakujace hashe":
    let dir = tmpDir("missing2")
    defer: removeDir(dir)
    let s = openStore(dir)
    let h1 = s.put(cast[seq[byte]]("obecny"))
    let h2 = hashBytes(cast[seq[byte]]("nieobecny"))
    let result = s.missing(@[h1, h2])
    check result == @[h2]

  test "listAll wylicza wszystkie zapisane obiekty":
    let dir = tmpDir("listall")
    defer: removeDir(dir)
    let s = openStore(dir)
    let h1 = s.put(cast[seq[byte]]("A"))
    let h2 = s.put(cast[seq[byte]]("B"))
    let h3 = s.put(cast[seq[byte]]("C"))
    let all = s.listAll()
    check all.len == 3
    check h1 in all
    check h2 in all
    check h3 in all

  test "deleteObject usuwa i jest idempotentny":
    let dir = tmpDir("delete")
    defer: removeDir(dir)
    let s = openStore(dir)
    let h = s.put(cast[seq[byte]]("do usuniecia"))
    check s.has(h)
    check s.deleteObject(h) == true
    check not s.has(h)
    check s.deleteObject(h) == false  # drugie usuniecie: nic do zrobienia, nie crashuje

  test "openStore zapisuje FORMAT przy pierwszym otwarciu i akceptuje przy kolejnych":
    let dir = tmpDir("format")
    defer: removeDir(dir)
    let s1 = openStore(dir)
    check s1.formatVersion == StoreFormatVersion
    check fileExists(dir / "FORMAT")
    let s2 = openStore(dir)  # kolejne otwarcie tego samego store
    check s2.formatVersion == StoreFormatVersion

  test "openStore odrzuca store z formatem nowszym niz obslugiwany":
    let dir = tmpDir("futureformat")
    defer: removeDir(dir)
    createDir(dir / "objects")
    writeFile(dir / "FORMAT", $(StoreFormatVersion + 1))
    expect StoreFormatError:
      discard openStore(dir)
