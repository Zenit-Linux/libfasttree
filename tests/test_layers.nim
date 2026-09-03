import std/[unittest, os, osproc, strutils]
import fasttree/layers

proc tmpDir(name: string): string =
  result = getTempDir() / "fasttree-test-layers-" & name & "-" & $getCurrentProcessId()
  removeDir(result)

proc makeTar(srcDir, tarPath: string) =
  createDir(srcDir.parentDir)
  let (output, code) = execCmdEx("tar -cf \"" & tarPath & "\" -C \"" & srcDir & "\" .")
  doAssert code == 0, "tar nie powiodl sie: " & output

suite "layers (OCI whiteout/scalanie)":
  test "dwie warstwy bez whiteout: druga po prostu nadpisuje/dodaje":
    let base = tmpDir("simple")
    defer: removeDir(base)
    let l0 = base / "l0"
    let l1 = base / "l1"
    createDir(l0 / "etc")
    writeFile(l0 / "etc" / "a.txt", "wersja 1")
    createDir(l1 / "etc")
    writeFile(l1 / "etc" / "a.txt", "wersja 2")
    writeFile(l1 / "etc" / "nowy.txt", "nowosc")

    makeTar(l0, base / "l0.tar")
    makeTar(l1, base / "l1.tar")

    let dest = materializeLayers(@[base / "l0.tar", base / "l1.tar"], base / "work", base / "dest")
    check readFile(dest / "etc" / "a.txt").strip() == "wersja 2"
    check readFile(dest / "etc" / "nowy.txt").strip() == "nowosc"

  test "whiteout pojedynczego pliku usuwa go z nizszej warstwy":
    let base = tmpDir("whiteout")
    defer: removeDir(base)
    let l0 = base / "l0"
    let l1 = base / "l1"
    createDir(l0 / "etc")
    writeFile(l0 / "etc" / "keep.txt", "zostaje")
    writeFile(l0 / "etc" / "gone.txt", "znika")
    createDir(l1 / "etc")
    writeFile(l1 / "etc" / ".wh.gone.txt", "")  # znacznik whiteout

    makeTar(l0, base / "l0.tar")
    makeTar(l1, base / "l1.tar")

    let dest = materializeLayers(@[base / "l0.tar", base / "l1.tar"], base / "work", base / "dest")
    check fileExists(dest / "etc" / "keep.txt")
    check not fileExists(dest / "etc" / "gone.txt")
    check not fileExists(dest / "etc" / ".wh.gone.txt")  # sam znacznik nie trafia do wyniku

  test "opaque whiteout czysci cala odziedziczona zawartosc katalogu":
    let base = tmpDir("opaque")
    defer: removeDir(base)
    let l0 = base / "l0"
    let l1 = base / "l1"
    createDir(l0 / "data")
    writeFile(l0 / "data" / "old1.txt", "stary1")
    writeFile(l0 / "data" / "old2.txt", "stary2")
    createDir(l1 / "data")
    writeFile(l1 / "data" / ".wh..wh..opq", "")  # opaque whiteout dla data/
    writeFile(l1 / "data" / "new.txt", "nowy")

    makeTar(l0, base / "l0.tar")
    makeTar(l1, base / "l1.tar")

    let dest = materializeLayers(@[base / "l0.tar", base / "l1.tar"], base / "work", base / "dest")
    check not fileExists(dest / "data" / "old1.txt")
    check not fileExists(dest / "data" / "old2.txt")
    check fileExists(dest / "data" / "new.txt")

  test "trzy warstwy: kolejnosc dol->gora respektowana":
    let base = tmpDir("threelayer")
    defer: removeDir(base)
    let l0 = base / "l0"; let l1 = base / "l1"; let l2 = base / "l2"
    createDir(l0); writeFile(l0 / "f.txt", "v1")
    createDir(l1); writeFile(l1 / "f.txt", "v2")
    createDir(l2); writeFile(l2 / "f.txt", "v3")
    makeTar(l0, base / "l0.tar")
    makeTar(l1, base / "l1.tar")
    makeTar(l2, base / "l2.tar")

    let dest = materializeLayers(@[base / "l0.tar", base / "l1.tar", base / "l2.tar"],
                                   base / "work", base / "dest")
    check readFile(dest / "f.txt").strip() == "v3"  # ostatnia warstwa wygrywa

  test "symlinki sa poprawnie kopiowane miedzy warstwami":
    let base = tmpDir("symlink")
    defer: removeDir(base)
    let l0 = base / "l0"
    createDir(l0)
    writeFile(l0 / "target.txt", "cel")
    createSymlink("target.txt", l0 / "link.txt")
    makeTar(l0, base / "l0.tar")

    let dest = materializeLayers(@[base / "l0.tar"], base / "work", base / "dest")
    check symlinkExists(dest / "link.txt")
    check expandSymlink(dest / "link.txt") == "target.txt"
