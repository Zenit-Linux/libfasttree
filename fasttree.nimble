version       = "0.2.0"
author        = "Zenit Developers"
description   = "FastTree — content-addressable, block-oriented następca OSTree (Nim, docelowo też Rust)"
license       = "MIT"
srcDir        = "src"
bin           = @["fasttreecli"]
binDir        = "bin"

# Dependencies

requires "nim >= 2.0.0"
requires "nimcrypto >= 0.6.0"   # fallback SHA-256 (-d:fasttreeNoBlake3); domyślnie używany jest BLAKE3 przez FFI

import std/[os, strformat, strutils]

task test, "Uruchamia testy jednostkowe (tests/*.nim)":
  ## Domyślnie z -d:fasttreeNoBlake3 — testy nie powinny wymagać zainstalowanej
  ## systemowej libblake3, żeby `nimble test` działało od razu po sklonowaniu
  ## repo. Testy specyficzne dla prawdziwego BLAKE3 są w `when UsingBlake3:`
  ## (patrz tests/test_hashing.nim) i pomijane w tym trybie.
  ## Ustaw FASTTREE_TEST_BLAKE3=1, żeby uruchomić z prawdziwym BLAKE3
  ## (wymaga zbudowanej/zainstalowanej libblake3 — patrz README).
  ##
  ## UWAGA implementacyjna: `exec` (nimscript) rzuca wyjątek przy niezerowym
  ## kodzie wyjścia procesu, więc każdy plik testowy jest owinięty w
  ## try/except, żeby jeden failing test nie przerwał reszty (chcemy pełny
  ## raport, nie zatrzymanie na pierwszym błędzie).
  let useBlake3 = existsEnv("FASTTREE_TEST_BLAKE3")
  var failed: seq[string] = @[]
  for file in listFiles("tests"):
    if file.endsWith(".nim") and file.extractFilename.startsWith("test_"):
      let defFlag = if useBlake3: "" else: "-d:fasttreeNoBlake3"
      let cmd = &"nim c -r --hints:off --path:src {defFlag} {file}"
      echo "\n=== ", file, " ==="
      try:
        exec(cmd)
      except OSError:
        failed.add file
  if failed.len > 0:
    echo "\nNIEPOWODZENIE w: ", failed.join(", ")
    quit(1)
  else:
    echo "\nWSZYSTKIE TESTY PRZESZŁY"
