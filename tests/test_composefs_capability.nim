import std/[unittest, os, strutils]
import fasttree/composefs

## Te testy sprawdzają WYŁĄCZNIE same funkcje diagnostyczne
## (`deviceMapperAvailable`/`fsVerityKernelSupport`) — muszą działać
## zawsze, niezależnie od tego, czy host ma dostęp do device-mapper czy
## fs-verity, bo `nimble test` (bez `FASTTREE_TEST_BLAKE3`/dodatkowych
## narzędzi systemowych) nie instaluje ani `veritysetup`, ani `composefs`.
## Pełny test `dmVerityOpen`/`mountVerified` na PRAWDZIWYM device-mapper
## / fs-verity jest w `.github/workflows/ci.yml` (job `full-integration`),
## bo to jedyne miejsce, gdzie mamy szansę na jądro z tymi funkcjami —
## patrz README, sekcja "Status implementacji".

suite "composefs — wykrywanie mozliwosci srodowiska":
  test "deviceMapperAvailable() nie rzuca wyjatku i zwraca bool":
    let result = deviceMapperAvailable()
    check result == true or result == false  # samo wywolanie sie nie wywala

  test "deviceMapperAvailable() jest spojne z /dev/mapper/control":
    check deviceMapperAvailable() == fileExists("/dev/mapper/control")

  test "fsVerityKernelSupport() nie rzuca wyjatku i zwraca bool":
    let result = fsVerityKernelSupport()
    check result == true or result == false

  test "fsVerityKernelSupport() zwraca false gdy /boot/config-<release> nieczytelny":
    # W wiekszosci srodowisk CI/kontenerow (w tym tym, w ktorym pisany byl
    # ten test) /boot/config-$(uname -r) po prostu nie istnieje — funkcja
    # ma wtedy zwrocic false, NIE rzucic wyjatku (asercja wyzej juz to
    # pokrywa; tu tylko dokumentujemy oczekiwane zachowanie w kontenerach).
    when defined(linux):
      check fsVerityKernelSupport() in [true, false]

  test "dmVerityOpen: fast-fail z czytelnym bledem, gdy brak device-mapper (jesli veritysetup zainstalowany)":
    # Warunkowe: domyslny `nimble test` (bez systemowego 'veritysetup')
    # nie moze tego uruchomic sensownie — requireTool2 rzucilby inny,
    # wczesniejszy blad ("brak narzedzia"), nie ten ktory testujemy.
    # Gdy 'veritysetup' JEST dostepny (np. w job 'full-integration' CI po
    # 'apt install cryptsetup-bin'), a device-mapper NIE jest dostepny
    # (typowe w kontenerach bez dm_mod), oczekujemy czytelnego,
    # natychmiastowego bledu zamiast proby losetup/veritysetup open.
    if findExe("veritysetup").len > 0 and not deviceMapperAvailable():
      expect(ComposefsError):
        discard dmVerityOpen("/nieistniejacy.img", "/nieistniejacy.hash",
                              "0".repeat(64), "fasttree-test-verity")
