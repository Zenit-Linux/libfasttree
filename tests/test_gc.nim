import std/[unittest, os, json]
import fasttree/gc
import fasttree/manifest
import fasttree/store

proc tmpDir(name: string): string =
  result = getTempDir() / "fasttree-test-gc-" & name & "-" & $getCurrentProcessId()
  removeDir(result)

proc setupRoot(root: string) =
  createDir(root / "store")
  createDir(root / "manifests")

suite "gc":
  test "liveTags: pusty root -> brak tagow":
    let root = tmpDir("empty")
    defer: removeDir(root)
    setupRoot(root)
    check liveTags(root).len == 0

  test "liveTags: CURRENT_TAG + pins.json, bez duplikatow":
    let root = tmpDir("tags")
    defer: removeDir(root)
    setupRoot(root)
    writeFile(root / "CURRENT_TAG", "v2")
    writeFile(root / "pins.json", $(%*[{"tag": "v1", "note": "x", "pinnedAt": "x"},
                                        {"tag": "v2", "note": "duplikat current", "pinnedAt": "x"}]))
    let tags = liveTags(root)
    check "v1" in tags
    check "v2" in tags
    check tags.len == 2  # v2 nie zduplikowany mimo ze jest i w CURRENT_TAG i w pins

  test "runGc: usuwa chunki nienalezace do zadnego zywego manifestu":
    let root = tmpDir("run")
    defer: removeDir(root)
    setupRoot(root)
    let s = openStore(root / "store")

    let onlyInOld = s.put(cast[seq[byte]]("tylko w starej wersji"))
    let sharedChunk = s.put(cast[seq[byte]]("wspolny chunk"))
    let onlyInNew = s.put(cast[seq[byte]]("tylko w nowej wersji"))

    let mOld = Manifest(
      formatVersion: FastTreeFormatVersion, hashAlgo: "test", root: onlyInOld,
      entries: @[FileEntry(path: "f.bin", mode: fmRegular, chunks: @[onlyInOld, sharedChunk])])
    let mNew = Manifest(
      formatVersion: FastTreeFormatVersion, hashAlgo: "test", root: onlyInNew,
      entries: @[FileEntry(path: "f.bin", mode: fmRegular, chunks: @[sharedChunk, onlyInNew])])

    writeFile(root / "manifests" / "old.json", $toJson(mOld))
    writeFile(root / "manifests" / "new.json", $toJson(mNew))
    writeFile(root / "CURRENT_TAG", "new")
    # "old" NIE jest przypiete ani current -> jego unikalny chunk powinien zniknac

    let res = runGc(root, dryRun = false)
    check res.scannedObjects == 3
    check res.deletedObjects == 1
    check res.liveObjects == 2  # sharedChunk + onlyInNew

    check not s.has(onlyInOld)
    check s.has(sharedChunk)
    check s.has(onlyInNew)

  test "runGc: dryRun nic nie usuwa, ale liczy statystyki":
    let root = tmpDir("dryrun")
    defer: removeDir(root)
    setupRoot(root)
    let s = openStore(root / "store")
    let orphan = s.put(cast[seq[byte]]("sierota"))
    # brak jakichkolwiek manifestow/tagow -> wszystko jest "martwe"

    let res = runGc(root, dryRun = true)
    check res.scannedObjects == 1
    check res.deletedObjects == 1  # policzone jako "zostalyby usuniete"
    check s.has(orphan)  # ale realnie NIE usuniete

  test "runGc: rzuca blad, gdy manifest zywego tagu nie istnieje na dysku":
    let root = tmpDir("missingmanifest")
    defer: removeDir(root)
    setupRoot(root)
    discard openStore(root / "store")
    writeFile(root / "CURRENT_TAG", "duch")  # nie ma manifests/duch.json
    expect IOError:
      discard runGc(root, dryRun = true)

  test "runGc: przypiety tag chroni jego chunki nawet gdy nie jest current":
    let root = tmpDir("pinprotect")
    defer: removeDir(root)
    setupRoot(root)
    let s = openStore(root / "store")
    let pinnedChunk = s.put(cast[seq[byte]]("chronione przez pin"))
    let currentChunk = s.put(cast[seq[byte]]("aktualne"))

    let mPinned = Manifest(formatVersion: FastTreeFormatVersion, hashAlgo: "test", root: pinnedChunk,
      entries: @[FileEntry(path: "f", mode: fmRegular, chunks: @[pinnedChunk])])
    let mCurrent = Manifest(formatVersion: FastTreeFormatVersion, hashAlgo: "test", root: currentChunk,
      entries: @[FileEntry(path: "f", mode: fmRegular, chunks: @[currentChunk])])
    writeFile(root / "manifests" / "pinned.json", $toJson(mPinned))
    writeFile(root / "manifests" / "cur.json", $toJson(mCurrent))
    writeFile(root / "CURRENT_TAG", "cur")
    writeFile(root / "pins.json", $(%*[{"tag": "pinned", "note": "chron mnie", "pinnedAt": "x"}]))

    let res = runGc(root, dryRun = false)
    check res.deletedObjects == 0
    check s.has(pinnedChunk)
    check s.has(currentChunk)
