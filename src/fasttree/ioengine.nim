import std/[asyncdispatch, asyncfutures]

type
  IoJob* = object
    path*: string
    data*: seq[byte]

when not defined(fasttreeIoUring):
  # --- Backend przenośny: asyncdispatch ------------------------------------
  import std/asyncfile
  type
    IoEngine* = ref object
      concurrency*: int

  proc newIoEngine*(concurrency = 64): IoEngine =
    IoEngine(concurrency: concurrency)

  proc close*(eng: IoEngine) =
    ## No-op w tym backendzie — asyncdispatch/asyncfile nie trzyma zasobów
    ## poza GC Nim. Istnieje wyłącznie dla symetrii API z backendem io_uring
    ## (gdzie `close()` zwalnia ring zaalokowany w C), żeby kod wołający
    ## (np. composefs.buildImage) mógł wołać `eng.close()` bez `when`.
    discard

  proc writeFileAsync*(eng: IoEngine, path: string, data: seq[byte]): Future[void] {.async.} =
    var f = openAsync(path, fmWrite)
    defer: f.close()
    await f.write(cast[string](data))

  proc writeBatch*(eng: IoEngine, jobs: seq[IoJob]): Future[void] {.async.} =
    var futs: seq[Future[void]] = @[]
    var inFlight = 0
    for job in jobs:
      futs.add eng.writeFileAsync(job.path, job.data)
      inc inFlight
      if inFlight >= eng.concurrency:
        await futs[^1]
        inFlight = 0
    for f in futs:
      if not f.finished:
        await f

  proc readFileAsync*(eng: IoEngine, path: string): Future[seq[byte]] {.async.} =
    var f = openAsync(path, fmRead)
    defer: f.close()
    let content = await f.readAll()
    result = newSeq[byte](content.len)
    if content.len > 0:
      copyMem(addr result[0], unsafeAddr content[0], content.len)

  proc readBatch*(eng: IoEngine, paths: seq[string]): Future[seq[seq[byte]]] {.async.} =
    ## Zwraca wyniki w TEJ SAMEJ kolejności co `paths` — istotne, bo wołający
    ## (np. composefs.buildImage) łączy wyniki z listą chunków po indeksie.
    result = newSeq[seq[byte]](paths.len)
    var futs = newSeq[Future[seq[byte]]](paths.len)
    var inFlight = 0
    for i, path in paths:
      futs[i] = eng.readFileAsync(path)
      inc inFlight
      if inFlight >= eng.concurrency:
        discard await futs[i]
        inFlight = 0
    for i, f in futs:
      result[i] = await f

else:
  # --- Backend io_uring (Linux, wymaga liburing-dev) -----------------------
  import std/[posix, strutils, os]

  {.passC: "-I/usr/include".}
  {.passL: "-luring".}

  type
    IoUringC {.importc: "struct io_uring", header: "liburing.h", incompleteStruct.} = object
    IoUringSqe {.importc: "struct io_uring_sqe", header: "liburing.h", incompleteStruct.} = object
    IoUringCqe {.importc: "struct io_uring_cqe", header: "liburing.h", incompleteStruct.} = object

  # `struct io_uring` ma rozmiar zależny od wersji liburing i zawiera wewnętrzne
  # wskaźniki/mmapy — zamiast zgadywać layout (jak przy BLAKE3), alokujemy go
  # WYŁĄCZNIE po stronie C (calloc), Nim trzyma tylko `ptr IoUringC` (opaque).
  {.emit: """
#include <liburing.h>
#include <stdlib.h>
struct io_uring *ftIoUringAlloc(void) { return calloc(1, sizeof(struct io_uring)); }
void ftIoUringFree(struct io_uring *r) { free(r); }
""".}
  proc ftIoUringAlloc(): ptr IoUringC {.importc, nodecl.}
  proc ftIoUringFree(r: ptr IoUringC) {.importc, nodecl.}

  proc io_uring_queue_init(entries: cuint, ring: ptr IoUringC, flags: cuint): cint
    {.importc, header: "liburing.h".}
  proc io_uring_queue_exit(ring: ptr IoUringC) {.importc, header: "liburing.h".}
  proc io_uring_get_sqe(ring: ptr IoUringC): ptr IoUringSqe {.importc, header: "liburing.h".}
  proc io_uring_prep_write(sqe: ptr IoUringSqe, fd: cint, buf: pointer,
                            nbytes: cuint, offset: uint64) {.importc, header: "liburing.h".}
  proc io_uring_prep_read(sqe: ptr IoUringSqe, fd: cint, buf: pointer,
                           nbytes: cuint, offset: uint64) {.importc, header: "liburing.h".}
  proc io_uring_sqe_set_data64(sqe: ptr IoUringSqe, data: uint64) {.importc, header: "liburing.h".}
  proc io_uring_submit(ring: ptr IoUringC): cint {.importc, header: "liburing.h".}
  proc io_uring_wait_cqe(ring: ptr IoUringC, cqePtr: ptr ptr IoUringCqe): cint
    {.importc, header: "liburing.h".}
  proc io_uring_cqe_get_data64(cqe: ptr IoUringCqe): uint64 {.importc, header: "liburing.h".}
  proc io_uring_cqe_seen(ring: ptr IoUringC, cqe: ptr IoUringCqe) {.importc, header: "liburing.h".}
  {.emit: """
#include <liburing.h>
int ftIoUringCqeRes(struct io_uring_cqe *cqe) { return cqe->res; }
""".}
  proc io_uring_cqe_res(cqe: ptr IoUringCqe): cint {.importc: "ftIoUringCqeRes", nodecl.}

  type
    IoUringError* = object of CatchableError

    IoEngine* = ref object
      concurrency*: int
      ring: ptr IoUringC
      queueDepth: int

  proc newIoEngine*(concurrency = 64): IoEngine =
    ## Kolejka SQ/CQ o głębokości `concurrency` — tyle operacji można mieć
    ## naraz "w locie" bez czekania na jądro.
    result = IoEngine(concurrency: concurrency, queueDepth: concurrency)
    result.ring = ftIoUringAlloc()
    let rc = io_uring_queue_init(cuint(result.queueDepth), result.ring, 0)
    if rc < 0:
      ftIoUringFree(result.ring)
      raise newException(IoUringError, "io_uring_queue_init nie powiodło się (kod " & $rc & ")")

  proc close*(eng: IoEngine) =
    ## Jawne zwolnienie kolejki io_uring. `IoEngine` trzyma zasób spoza GC
    ## Nim (ring zaalokowany przez `calloc` w C) — zamiast opierać się na
    ## kruchym w kombinacji z FFI hooku `=destroy` na polu `ref object`,
    ## wołający sam decyduje kiedy zamknąć silnik (np. `defer: eng.close()`
    ## zaraz po `newIoEngine()`).
    if eng.ring != nil:
      io_uring_queue_exit(eng.ring)
      ftIoUringFree(eng.ring)
      eng.ring = nil

  proc ioUringWriteBatch(eng: IoEngine, jobs: seq[IoJob]) =
    ## Rdzeń backendu: otwiera pliki docelowe, submituje WSZYSTKIE zapisy
    ## partii jednym `io_uring_submit`, czeka na wszystkie completions (CQE),
    ## sprawdza kod wyniku każdego zapisu, zamyka pliki.
    if jobs.len == 0: return
    if jobs.len > eng.queueDepth:
      # Partia większa niż głębokość kolejki — dzielimy rekurencyjnie,
      # zamiast przepełniać SQ (io_uring_get_sqe zwróciłby nil).
      ioUringWriteBatch(eng, jobs[0 ..< eng.queueDepth])
      ioUringWriteBatch(eng, jobs[eng.queueDepth ..< jobs.len])
      return

    var fds = newSeq[cint](jobs.len)
    for i, job in jobs:
      let fd = posix.open(job.path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o644)
      if fd < 0:
        # Zamknij to, co już otwarte, zanim zgłosimy błąd — bez wycieku fd.
        for j in 0 ..< i: discard posix.close(fds[j])
        raise newException(IoUringError, "open() nie powiódł się dla " & job.path)
      fds[i] = fd

      let sqe = io_uring_get_sqe(eng.ring)
      if sqe == nil:
        raise newException(IoUringError, "io_uring_get_sqe zwróciło nil — SQ pełne")
      let dataPtr = if job.data.len > 0: unsafeAddr job.data[0] else: nil
      io_uring_prep_write(sqe, fd, dataPtr, cuint(job.data.len), 0'u64)
      io_uring_sqe_set_data64(sqe, uint64(i))

    let submitted = io_uring_submit(eng.ring)
    if submitted < 0 or submitted.int != jobs.len:
      for fd in fds: discard posix.close(fd)
      raise newException(IoUringError,
        "io_uring_submit zgłosiło " & $submitted & " z oczekiwanych " & $jobs.len)

    var completed = 0
    var errors: seq[string] = @[]
    while completed < jobs.len:
      var cqe: ptr IoUringCqe
      let rc = io_uring_wait_cqe(eng.ring, addr cqe)
      if rc < 0:
        errors.add "io_uring_wait_cqe błąd: " & $rc
        break
      let idx = io_uring_cqe_get_data64(cqe).int
      let res = io_uring_cqe_res(cqe)
      if res < 0:
        errors.add "zapis '" & jobs[idx].path & "' nie powiódł się (errno " & $(-res) & ")"
      elif res.int != jobs[idx].data.len:
        errors.add "niepełny zapis '" & jobs[idx].path & "': " & $res & "/" & $jobs[idx].data.len & " B"
      io_uring_cqe_seen(eng.ring, cqe)
      inc completed

    for fd in fds: discard posix.close(fd)
    if errors.len > 0:
      raise newException(IoUringError, "writeBatch: " & errors.len.`$` & " błędów: " & errors.join("; "))

  proc ioUringReadBatch(eng: IoEngine, paths: seq[string]): seq[seq[byte]] =
    ## Analogiczny wzorzec do ioUringWriteBatch, ale w drugą stronę: bufory
    ## alokujemy PRZED submitem na podstawie rozmiaru pliku (io_uring_prep_read
    ## potrzebuje gotowego bufora o znanej długości — w przeciwieństwie do
    ## POSIX read(2) nie ma tu "czytaj ile się da"). Wynik w TEJ SAMEJ
    ## kolejności co `paths`, niezależnie od kolejności ukończenia CQE (stąd
    ## `io_uring_sqe_set_data64(sqe, uint64(i))` — indeks, nie ścieżka).
    if paths.len == 0: return @[]
    if paths.len > eng.queueDepth:
      result = ioUringReadBatch(eng, paths[0 ..< eng.queueDepth])
      result.add ioUringReadBatch(eng, paths[eng.queueDepth ..< paths.len])
      return

    var fds = newSeq[cint](paths.len)
    var bufs = newSeq[seq[byte]](paths.len)
    for i, path in paths:
      let fd = posix.open(path.cstring, O_RDONLY)
      if fd < 0:
        for j in 0 ..< i: discard posix.close(fds[j])
        raise newException(IoUringError, "open() (odczyt) nie powiódł się dla " & path)
      fds[i] = fd

      let sz = getFileSize(path)
      bufs[i] = newSeq[byte](sz.int)

      let sqe = io_uring_get_sqe(eng.ring)
      if sqe == nil:
        raise newException(IoUringError, "io_uring_get_sqe zwróciło nil — SQ pełne")
      let bufPtr = if bufs[i].len > 0: addr bufs[i][0] else: nil
      io_uring_prep_read(sqe, fds[i], bufPtr, cuint(bufs[i].len), 0'u64)
      io_uring_sqe_set_data64(sqe, uint64(i))

    let submitted = io_uring_submit(eng.ring)
    if submitted < 0 or submitted.int != paths.len:
      for fd in fds: discard posix.close(fd)
      raise newException(IoUringError,
        "io_uring_submit (odczyt) zgłosiło " & $submitted & " z oczekiwanych " & $paths.len)

    var completed = 0
    var errors: seq[string] = @[]
    while completed < paths.len:
      var cqe: ptr IoUringCqe
      let rc = io_uring_wait_cqe(eng.ring, addr cqe)
      if rc < 0:
        errors.add "io_uring_wait_cqe błąd: " & $rc
        break
      let idx = io_uring_cqe_get_data64(cqe).int
      let res = io_uring_cqe_res(cqe)
      if res < 0:
        errors.add "odczyt '" & paths[idx] & "' nie powiódł się (errno " & $(-res) & ")"
      elif res.int != bufs[idx].len:
        errors.add "niepełny odczyt '" & paths[idx] & "': " & $res & "/" & $bufs[idx].len & " B"
      io_uring_cqe_seen(eng.ring, cqe)
      inc completed

    for fd in fds: discard posix.close(fd)
    if errors.len > 0:
      raise newException(IoUringError, "readBatch: " & errors.len.`$` & " błędów: " & errors.join("; "))
    bufs

  proc readFileAsync*(eng: IoEngine, path: string): Future[seq[byte]] {.async.} =
    result = ioUringReadBatch(eng, @[path])[0]

  proc readBatch*(eng: IoEngine, paths: seq[string]): Future[seq[seq[byte]]] {.async.} =
    ## Wsadowy odczyt wielu obiektów store'a jednym `io_uring_submit` —
    ## docelowe miejsce użycia: `composefs.buildImage`, które dziś czyta
    ## chunki sekwencyjnie przez `store.get` (patrz TODO tam).
    result = ioUringReadBatch(eng, paths)

  proc writeFileAsync*(eng: IoEngine, path: string, data: seq[byte]): Future[void] {.async.} =
    ## Zachowuje sygnaturę async dla zgodności z resztą kodu (store.nim,
    ## oci.nim), ale wykonuje pracę synchronicznie przez io_uring — pojedynczy
    ## zapis to i tak jedno SQE, `await` po prostu wraca natychmiast po jego
    ## ukończeniu.
    ioUringWriteBatch(eng, @[IoJob(path: path, data: data)])

  proc writeBatch*(eng: IoEngine, jobs: seq[IoJob]): Future[void] {.async.} =
    ## To jest właściwe miejsce zysku wydajnościowego: cała `jobs` submitowana
    ## jednym `io_uring_submit`, niezależnie od `eng.concurrency` (który tu
    ## odpowiada głębokości kolejki SQ/CQ, nie liczbie równoległych Future).
    ioUringWriteBatch(eng, jobs)
