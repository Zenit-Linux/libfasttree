import std/[strutils]

const UsingBlake3* = not defined(fasttreeNoBlake3)

type
  Hash* = object
    ## 32-bajtowy skrót — węzeł drzewa Merkle FastTree.
    bytes*: array[32, byte]

proc `==`*(a, b: Hash): bool {.inline.} = a.bytes == b.bytes

proc `$`*(h: Hash): string =
  result = newStringOfCap(64)
  for b in h.bytes:
    result.add toHex(b.int, 2).toLowerAscii

proc hashFromHex*(s: string): Hash =
  ## UWAGA: to jedna z niewielu funkcji w bibliotece Nim wołana bezpośrednio
  ## z wejściem pochodzącym zza granicy FFI (capi.nim: ft_store_get/ft_store_has
  ## dostają hex od Rust/C). Dlatego walidacja rzuca zwykły `ValueError`
  ## (catchable), a NIE `doAssert`/Defect — Defect przechodzi przez
  ## `except CatchableError` w capi.nim i ubiłby cały proces wołającego
  ## przy zwykłym błędnym wejściu, zamiast zwrócić FT_ERR_INVALID_ARGUMENT.
  if s.len != 64:
    raise newException(ValueError, "oczekiwano 64 znaków hex (32 bajty), otrzymano " & $s.len)
  for i in 0 ..< 32:
    result.bytes[i] = byte(parseHexInt(s[i*2 .. i*2+1]))

when UsingBlake3:
  # --- FFI do libblake3 --------------------------------------------------
  # Wymaga linkowania z -lblake3 (paczka systemowa lub zbudowana z sources
  # BLAKE3-team/BLAKE3/c, patrz README -> "Budowanie z BLAKE3"). Deklaracje
  # odzwierciedlają blake3.h z referencyjnego repo BLAKE3-team/BLAKE3.
  {.passC: "-I/usr/local/include".}
  {.passL: "-L/usr/local/lib -lblake3".}

  const BLAKE3_OUT_LEN = 32

  type Blake3HasherC {.importc: "blake3_hasher", header: "blake3.h".} = object
    # Nieprzezroczysta struktura po stronie C — Nim rezerwuje miejsce jako
    # surowy bufor bajtów. Rozmiar zweryfikowany względem referencyjnego
    # blake3.h (BLAKE3-team/BLAKE3 @ c/blake3.h): key[8]*u32 + chunk_state +
    # cv_stack_len + cv_stack[(BLAKE3_MAX_DEPTH+1)*BLAKE3_OUT_LEN] = 1912 B
    # na x86-64 (sizeof zweryfikowany programem C przy kompilacji tego repo).
    # Runtime sanity-check poniżej (ftBlake3NativeSizeof) łapie rozjazd,
    # gdyby ktoś zbudował/podlinkował inną wersję libblake3.
    opaque: array[1912, byte]

  proc blake3_hasher_init(self: ptr Blake3HasherC) {.importc, header: "blake3.h".}
  proc blake3_hasher_update(self: ptr Blake3HasherC, input: pointer, inputLen: csize_t) {.importc, header: "blake3.h".}
  proc blake3_hasher_finalize(self: ptr Blake3HasherC, output: ptr byte, outLen: csize_t) {.importc, header: "blake3.h".}

  {.emit: """
#include <blake3.h>
size_t ftBlake3NativeSizeof(void) { return sizeof(blake3_hasher); }
""".}
  proc ftBlake3NativeSizeof(): csize_t {.importc, nodecl.}

  var blake3AbiChecked = false

  proc verifyBlake3Abi*() =
    ## Wywoływane raz (leniwie, przy pierwszym `initHasher`) — porównuje
    ## rozmiar struktury zarezerwowany po stronie Nim z prawdziwym
    ## `sizeof(blake3_hasher)` zwróconym przez podlinkowaną libblake3.
    ## Rozjazd (np. po aktualizacji libblake3 do wersji ze zmienionym
    ## layoutem) kończy się jasnym błędem zamiast cichej korupcji pamięci.
    if blake3AbiChecked: return
    let native = ftBlake3NativeSizeof()
    if native.int != sizeof(Blake3HasherC):
      raise newException(AssertionDefect,
        "Niezgodność ABI BLAKE3: Nim rezerwuje " & $sizeof(Blake3HasherC) &
        " B, podlinkowana libblake3 zgłasza sizeof(blake3_hasher)=" & $native &
        " B. Sprawdź wersję blake3.h i zaktualizuj rozmiar tablicy 'opaque' w hashing.nim.")
    blake3AbiChecked = true

  type Hasher* = object
    c: Blake3HasherC

  proc initHasher*(): Hasher =
    verifyBlake3Abi()
    blake3_hasher_init(addr result.c)

  proc update*(h: var Hasher, data: openArray[byte]) =
    if data.len > 0:
      blake3_hasher_update(addr h.c, unsafeAddr data[0], csize_t(data.len))

  proc finalize*(h: var Hasher): Hash =
    blake3_hasher_finalize(addr h.c, addr result.bytes[0], csize_t(BLAKE3_OUT_LEN))

else:
  # --- Fallback: SHA-256 przez nimcrypto ---------------------------------
  import nimcrypto/sha2

  type Hasher* = object
    c: sha256

  proc initHasher*(): Hasher =
    result.c.init()

  proc update*(h: var Hasher, data: openArray[byte]) =
    if data.len > 0:
      h.c.update(data)

  proc finalize*(h: var Hasher): Hash =
    let digest = h.c.finish()
    h.c.clear()
    result.bytes = digest.data

const AlgoName* = (when UsingBlake3: "blake3" else: "sha256-fallback")
  ## Nazwa algorytmu haszującego użytego w tej kompilacji — zapisywana
  ## w manifeście (manifest.nim), żeby dwóch manifestów policzonych różnymi
  ## backendami (blake3 vs fallback sha256) nigdy nie dało się pomylić przez
  ## proste porównanie root-hash (identyczne drzewo, inny algorytm = inny hash).

proc hashBytes*(data: openArray[byte]): Hash =
  ## Skrót pojedynczego bloku danych (np. chunku pliku).
  var h = initHasher()
  h.update(data)
  h.finalize()

proc hashChildren*(children: openArray[Hash]): Hash =
  ## Węzeł wewnętrzny drzewa Merkle: skrót konkatenacji skrótów dzieci.
  ## Używane do budowy roota manifestu z hashy plików/chunków.
  var buf = newSeq[byte](children.len * 32)
  for i, c in children:
    buf[i*32 ..< i*32+32] = c.bytes
  hashBytes(buf)
