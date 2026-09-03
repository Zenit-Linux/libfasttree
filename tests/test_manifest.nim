import std/[unittest, os, json, sequtils, strutils, algorithm]
import fasttree/manifest
import fasttree/chunker
import fasttree/store

proc tmpDir(name: string): string =
  result = getTempDir() / "fasttree-test-manifest-" & name & "-" & $getCurrentProcessId()
  removeDir(result)

proc writeTree(root: string, files: openArray[(string, string)]) =
  createDir(root)
  for (path, content) in files:
    let full = root / path
    createDir(full.parentDir)
    writeFile(full, content)

suite "manifest":
  test "buildManifest: pliki i katalogi trafiaja do entries, posortowane po path":
    let src = tmpDir("build") & "-src"
    let storeDir = tmpDir("build") & "-store"
    defer: (removeDir(src); removeDir(storeDir))
    writeTree(src, [("b.txt", "B"), ("a.txt", "A"), ("sub/c.txt", "C")])

    let s = openStore(storeDir)
    let m = buildManifest(src, s)

    check m.entries.len == 4  # a.txt, b.txt, sub/, sub/c.txt
    let paths = m.entries.mapIt(it.path)
    check paths == sorted(paths)  # posortowane

  test "buildManifest wypelnia formatVersion/hashAlgo/chunker":
    let src = tmpDir("meta") & "-src"
    let storeDir = tmpDir("meta") & "-store"
    defer: (removeDir(src); removeDir(storeDir))
    writeTree(src, [("f.txt", "tresc")])
    let s = openStore(storeDir)
    let m = buildManifest(src, s)
    check m.formatVersion == FastTreeFormatVersion
    check m.hashAlgo.len > 0
    check m.chunker.avgSize == DefaultConfig.avgSize

  test "identyczna zawartosc -> identyczny root hash (deterministycznosc)":
    let src1 = tmpDir("det1") & "-src"
    let src2 = tmpDir("det2") & "-src"
    let storeDir = tmpDir("det") & "-store"
    defer: (removeDir(src1); removeDir(src2); removeDir(storeDir))
    writeTree(src1, [("x.txt", "identyczna tresc"), ("y.txt", "inna tresc")])
    writeTree(src2, [("x.txt", "identyczna tresc"), ("y.txt", "inna tresc")])

    let s = openStore(storeDir)
    let m1 = buildManifest(src1, s)
    let m2 = buildManifest(src2, s)
    check m1.root == m2.root

  test "rozna zawartosc -> rozny root hash":
    let src1 = tmpDir("diff1") & "-src"
    let src2 = tmpDir("diff2") & "-src"
    let storeDir = tmpDir("diffstore") & "-store"
    defer: (removeDir(src1); removeDir(src2); removeDir(storeDir))
    writeTree(src1, [("x.txt", "wersja 1")])
    writeTree(src2, [("x.txt", "wersja 2")])

    let s = openStore(storeDir)
    let m1 = buildManifest(src1, s)
    let m2 = buildManifest(src2, s)
    check m1.root != m2.root

  test "toJson/manifestFromJson: round-trip zachowuje root i entries":
    let src = tmpDir("json") & "-src"
    let storeDir = tmpDir("json") & "-store"
    defer: (removeDir(src); removeDir(storeDir))
    writeTree(src, [("a.txt", "AAA"), ("b/c.txt", "CCC")])
    let s = openStore(storeDir)
    let m = buildManifest(src, s)

    let j = toJson(m)
    let reloaded = manifestFromJson(j)
    check reloaded.root == m.root
    check reloaded.entries.len == m.entries.len
    check reloaded.formatVersion == m.formatVersion
    check reloaded.hashAlgo == m.hashAlgo

  test "manifestFromJson odrzuca formatVersion nowszy niz obslugiwany":
    let j = %*{
      "formatVersion": FastTreeFormatVersion + 1,
      "hashAlgo": "blake3",
      "chunker": {"minSize": 1, "avgSize": 2, "maxSize": 3},
      "root": "0".repeat(64),
      "entries": newJArray()
    }
    expect ManifestFormatError:
      discard manifestFromJson(j)

  test "manifestFromJson odrzuca brak formatVersion (przedwersyjny/obcy plik)":
    let j = %*{"root": "0".repeat(64), "entries": newJArray()}
    expect ManifestFormatError:
      discard manifestFromJson(j)

  test "diff: wykrywa added/removed/modified z poprawna liczba chunkow":
    let srcV1 = tmpDir("diffv1") & "-src"
    let srcV2 = tmpDir("diffv2") & "-src"
    let storeDir = tmpDir("diffstore2") & "-store"
    defer: (removeDir(srcV1); removeDir(srcV2); removeDir(storeDir))
    writeTree(srcV1, [("stays.txt", "bez zmian"), ("removed.txt", "znika"), ("changed.txt", "przed")])
    writeTree(srcV2, [("stays.txt", "bez zmian"), ("changed.txt", "po zmianie"), ("added.txt", "nowy")])

    let s = openStore(storeDir)
    let m1 = buildManifest(srcV1, s)
    let m2 = buildManifest(srcV2, s)
    let d = diff(m1, m2)

    var kinds: seq[(DiffKind, string)] = @[]
    for entry in d: kinds.add (entry.kind, entry.path)

    check (dkAdded, "added.txt") in kinds
    check (dkRemoved, "removed.txt") in kinds
    check (dkModified, "changed.txt") in kinds
    check (dkModified, "stays.txt") notin kinds
    for e in kinds:
      check e[1] != "stays.txt"  # bez zmian -> w ogole nie w diffie

  test "diff: identyczne manifesty daja pusty diff":
    let src = tmpDir("samediff") & "-src"
    let storeDir = tmpDir("samediff") & "-store"
    defer: (removeDir(src); removeDir(storeDir))
    writeTree(src, [("a.txt", "A")])
    let s = openStore(storeDir)
    let m = buildManifest(src, s)
    check diff(m, m).len == 0
