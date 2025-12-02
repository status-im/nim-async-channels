# Overview
#
# This example demonstrates several approaches to performing background work
# (reading files, hashing) while keeping the coordinating thread responsive.
#
# It shows:
#  - Synchronous single-threaded processing (readFilesSingle)
#  - Thread-pipeline using `Channel` passing work between stages (readFilesThread)
#  - `async`-friendly mixed `Channel` and `AsyncChannel` pipeline passing work between stages (readFilesAsync)
#  - Threaded worker pool using Channels and per-thread IO workers (Pool)
#  - mmap-based reader for large files (computeHashMmap)
#
# High-level comparison
#  - readFilesSingle
#    * Simplicity: trivial, no concurrency
#    * Blocks the caller while doing I/O + CPU work
#
#  - readFilesThread (pipeline of threads + Channels)
#    * Good separation of concerns (reader | hasher | printer)
#    * Ordering preserved per pipeline path
#    * Instead of a single thread per task, a task-specific pool could be used
#
#  - Pool / worker (thread pool)
#    * Scales reading and hashing across worker threads
#    * Allows multiple independent hashers to work concurrently
#    * Uses Channel/AsyncChannel messages to feed tasks and gather results
#
#  - Chronos async (readFilesAsync, readFilesPool)
#    * Integrates with Chronos event loop (non-blocking)
#    * Useful when mixing many concurrent I/O operations or integrating with other async APIs
#
#  - mmap (computeHashMmap)
#    * Minimal copies, allows processing large files (zero-copy reading)
#    * Beware of platform-specific semantics and memory pressure
#
# Ownership, lifetime and errors
#  - SharedBuf is used to transfer large buffers between threads: ownership must be
#    transferred and destroy() must be called by the final owner (examples show payload.destroy()).
#  - Channels carry Opt[T] (or default sentinel) to signal shutdown; consumers should handle
#    missing values and sentinel messages gracefully.
#  - Many functions return Result to indicate errors - errors and metadata are passed along
#    through the pipeline to read the final consumer
#
# Practical tips
#  - Always signal termination: send default(channel.TMsg) or Opt.none sentinel
#    so consumers know when to stop.
#  - For robust apps, collect and log errors rather than crashing; convert exceptions into
#    Result/Opt return values when crossing thread/async boundaries.
#
# The rest of this file contains the concrete implementations and small tests that
# illustrate each approach. Read the per-function doc comments (where present) for details.

import
  std/[concurrency/cpuinfo, dirs, memfiles, paths, sequtils, typetraits],
  stew/[io2],
  nimcrypto/[sha2, hash, utils],
  results,
  ../asyncchannels,
  ./utils/sharedbuf

# Pass errors around using a string for simplicity
type
  Res[T] = Result[T, string]
  Digest = array[32, byte]

type FilesIter = iterator (): string {.raises: [], gcsafe.}
proc makeTasks(): FilesIter =
  # A simple "work generator" - in this case, an iterator that walks the files
  # of the current directory - instead of posting all work to the channel at
  # once, the work could be loaded lazily as readFilesBounded shows.
  iterator (): string =
    try:
      for f in walkDir(Path("."), relative = true):
        if f.kind != pcFile:
          continue

        yield string(f.path)
    except CatchableError:
      discard # Ignore errors here for demonstration purposes

proc readData(path: string): Res[SharedBuf] =
  ## Read all bytes of `path` into a shared buffer suitable for passing between
  ## threads.
  ##
  ## A more sophisticate approach would read file in chunks and process each
  ## chunk individually with a backpressure mechanism between reading and
  ## further processing!
  let handle = ?openFile(path, {OpenFlags.Read}).mapErr(ioErrorMsg)

  defer:
    discard handle.closeFile()

  let size = ?handle.getFileSize().mapErr(ioErrorMsg)
  if size > int64(int32.high() div 2):
    return err("File too big")

  var payload = SharedBuf.create(int(size))
  defer:
    payload.destroy()

  let len = ?readFile(handle, payload.data).mapErr(ioErrorMsg)

  if len != payload.len.uint:
    return err("Could not read entire file")

  # move ensures we don't destroy the payload
  ok move(payload)

proc sha256digest(data: openArray[byte]): Digest =
  ## Return the sha256 digest of the given data using bearssl, which we get for
  ## free because chronos already depends on it!
  Digest(sha256.digest(data).data)

type
  IoProc[Args, Result] = proc(a: Args): Result {.nimcall, raises: [], gcsafe.}
  SyncChannel[T] = Channel[Opt[T]]

template SomeChannel[T](async: static bool): typedesc =
  ## Select either chronos or std channel - we use Opt[T] in order to be able
  ## to shut down the channel with `none`.
  when async:
    AsyncChannel[Opt[T]]
  else:
    Channel[Opt[T]]

template send(c: AsyncChannel, msg: auto): untyped =
  c.sendSync(msg)

template TArg[A, B](async: static bool): typedesc =
  tuple[r: ptr SyncChannel[A], w: ptr SomeChannel[B](async), p: IoProc[A, B]]

type
  NamedRes[T] = tuple[name: string, res: Res[T]]

  Pipeline[async: static bool] = object
    ## A simple threaded pipeline where reading reading and hashing happens on
    ## separate threads and work is passed along from one channel to the other.
    readChan: SyncChannel[string]
    hashChan: SyncChannel[NamedRes[SharedBuf]]
    digestChan: SomeChannel[NamedRes[Digest]](async)

    readThread: Thread[TArg[string, NamedRes[SharedBuf]](false)]
    hashThread: Thread[TArg[NamedRes[SharedBuf], NamedRes[Digest]](async)]

proc readDataTask(name: string): NamedRes[SharedBuf] =
  # Pass the name along so that when reading results out of order, we still know
  # which file it is
  (name, readData(name))

proc hashTask(v: NamedRes[SharedBuf]): NamedRes[Digest] =
  if v.res.isErr():
    # Pass error along..
    (v[0], Res[Digest].err(v.res.error))
  else:
    var payload = v[1][]
    let digest = sha256digest(payload.data())

    payload.destroy()
    (v[0], Res[Digest].ok digest)

proc print(v: NamedRes[Digest]) =
  if v.res.isOk():
    echo v.res[].toHex(lowercase = true), " ", v.name
  else:
    echo v.res.error(), " ", v.name

proc readFilesSingle(files: FilesIter) =
  ## Single-threaded reference approach for reading and hashing a file
  for name in files():
    print(hashTask(readDataTask(name)))

proc pipelineWorker[TArg](p: TArg) {.thread.} =
  # Read item from `p.r`, process it with `p.p` then pass it on to `p.w`
  while true:
    var item = p.r[].recv().valueOr:
      break

    let res = p.p(item)
    p.w[].send(Opt.some(res))

  p.w[].send(default(p.w[].TMsg))

proc open(v: var Pipeline) =
  v.readChan.open()
  v.hashChan.open()

  when v.digestChan is Channel:
    v.digestChan.open()
  else:
    v.digestChan.open().expect("can open channels")

  v.readThread.createThread(
    pipelineWorker[v.readThread.TArg], (addr v.readChan, addr v.hashChan, readDataTask)
  )
  v.hashThread.createThread(
    pipelineWorker[v.hashThread.TArg], (addr v.hashChan, addr v.digestChan, hashTask)
  )

proc close(v: var Pipeline) =
  v.readChan.close()
  v.hashChan.close()
  v.digestChan.close()

  joinThread(v.readThread)
  joinThread(v.hashThread)

proc readFilesThread(files: FilesIter) =
  ## Pipeline approach using 2 worker threads - one for reading data and the
  ## other for hashing - this approach could fruitfully be combined with two
  ## pools instead of two thread - one for I/O and one for computations to
  ## further adapt the work load to the system it runs on.
  ##
  ## The main goal of this approach is to demonstrate the passing of
  ## unmanaged buffers between threads allowing reading and hashing to take
  ## place concurrently.
  var pipeline: Pipeline[false]
  pipeline.open()

  for f in files():
    pipeline.readChan.send(Opt.some(f))

  pipeline.readChan.send(default(pipeline.readChan.TMsg))

  while true:
    let res = pipeline.digestChan.recv().valueOr:
      break

    print(res)

  pipeline.close()

proc readFilesAsync(files: FilesIter) {.async.} =
  ## This is the same pipeline as above, but instead of an ordinary thread, here
  ## we're inside an async function that is (potentially) doing other work
  ## as well, such as managing a network.
  ##
  ## Work is posted from the network thread and results come back there for
  ## printing - otherwise, it is equivalent to the previous solution.
  var pipeline: Pipeline[true]
  pipeline.open()

  for f in files():
    pipeline.readChan.send2(Opt.some(f))

  pipeline.readChan.send2(default(pipeline.readChan.TMsg))

  while true:
    let item = await(addr(pipeline.digestChan).recv()).valueOr:
      break

    print(item)

  pipeline.close()

type
  Io[Args, Result] = object
    ## Similar to the pipeline, the Io type represents a single function call
    ## whose arguments get read from one channel and results get posted to
    ## another
    r: ptr Channel[Opt[(Args, pointer)]]
    w: ptr AsyncChannel[(Result, pointer)]
    p: IoProc[Args, Result]

  Pool[Args, Result] = object
    workers: seq[Thread[Io[Args, Result]]]
    r: Channel[Opt[(Args, pointer)]]
    w: AsyncChannel[(Result, pointer)]
    loop: Future[void]

proc close(p: var Pool) =
  p.loop.cancelSoon()

  for i in 0 ..< p.workers.len:
    p.r.send2(Opt.none(p.r.TMsg.T))

  for w in p.workers.mitems():
    w.joinThread()
  p.workers.reset()

proc computeHash(name: string): NamedRes[Digest] =
  hashTask(readDataTask(name))

proc computeHashMmap(name: string): NamedRes[Digest] =
  try:
    var mf = memfiles.open(name)
    defer:
      mf.close()
    let p = cast[ptr UncheckedArray[byte]](mf.mem)

    (name, Res[Digest].ok(sha256digest(p.toOpenArray(0, mf.size - 1))))
  except Exception as exc:
    (name, Res[Digest].err(exc.msg))

proc ioworker(p: Io) {.thread.} =
  while true:
    let (args, udata) = p.r[].recv().valueOr:
      break

    p.w[].send((p.p(args), udata))

proc poolWorker(p: ref Pool) {.async: (raises: []).} =
  # Results may arrive out-of-order so we use this worker to match result to
  # corresponding future
  try:
    while true:
      let (data, p) = await (addr p.w).recv()
      let fut = cast[Future[typeof(data)]](p)
      GC_unref(fut)

      if not fut.finished():
        fut.complete(data)
  except CancelledError:
    discard

proc new[Args, Result](
    T: type Pool[Args, Result], threads: int, io: IoProc[Args, Result]
): ref Pool[Args, Result] =
  let res = (ref Pool[Args, Result])(workers: newSeq[Thread[Io[Args, Result]]](threads))

  res.r.open()
  res.w.open().expect("working channel")

  for w in res.workers.mitems():
    w.createThread(ioworker, Io[Args, Result](r: addr res.r, w: addr res.w, p: io))

  res.loop = poolWorker(res)

  res

proc compute[Args, Result](
    pool: ref Pool[Args, Result], handle: Args
): Future[Result] {.async: (raw: true).} =
  let fut = newFuture[Result]()

  GC_ref(fut) # Keep the future alive until
  pool.r.send2(Opt.some((handle, cast[pointer](fut))))

  fut

proc readFilesPool(files: FilesIter) {.async.} =
  ## This example shows how to use a worker pool, posting jobs to its job queue
  ## and reading the results back.
  ##
  ## While the results may appear in random order in the result queue, we keep
  ## track of "job-result" mapping via a user data pointer that allows us to
  ## complete the correct future for each job allowing the results to be printed
  ## in order of iteration without too much hassle.
  ##
  ## If maintaining order of outcomes is not needed, the pool can be further
  ## simplified, removing the `loop` helper entirely.
  ##
  ## Each task consists of both reading and hashing - this is a simple and
  ## robust approach that performs well on modern hardware with SSD-style
  ## disk drives.
  let threads = min(16, max(2, countProcessors()))
  var pool = Pool[string, NamedRes[Digest]].new(threads, computeHash)

  var inflight: seq[Future[pool.Result]]
  for f in files():
    inflight.add pool.compute(f)

  for compute in inflight:
    print(await compute)

  pool[].close()

proc readFilesMmap(files: FilesIter) {.async.} =
  ## This is an example similar to the pool example above but instead using
  ## memory maps to access the data - the downside of memory mapping is that
  ## error handling becomes more difficult (since they lead to faults that must
  ## be caught using platform-dependent fault handling mechanisms).
  ##
  ## A more complete example would also deal with 32-bit environments by
  ## processing the file in reasonably sized chunks, a feature missing also from
  ## the above file readers.
  let threads = min(16, max(2, countProcessors()))

  var pool = Pool[string, NamedRes[Digest]].new(threads, computeHashMmap)

  var inflight: seq[Future[pool.Result]]
  for f in files():
    inflight.add pool.compute(f)

  for x in inflight:
    print(await x)

  pool[].close()

proc readFilesBounded(files: FilesIter) {.async.} =
  ## This time, we use the same pool approach as above but put an upper bound
  ## on the number of jobs we post to the queue.
  ##
  ## Each time the queue is full, we wait for at least one of the jobs to finish
  ## before posting additional ones - this ends up working like a backpressure
  ## mechanism to ensure that the queue does not overflow with work.
  let
    threads = min(16, max(2, countProcessors()))
    bound = 2 * threads
      # Provide enough jobs in the queue such that workers likely have something
      # to work on if they finish one job and want to move on to the next

  var pool = Pool[string, NamedRes[Digest]].new(threads, computeHashMmap)

  # Sequence of in-flight jobs suitable when bounds are small
  var inflight: seq[Future[pool.Result]]

  proc processSome() {.async.} =
    while inflight.len >= bound:
      discard await race(inflight)

      inflight.keepItIf:
        if it.finished:
          print(it.value)
          false
        else:
          true

  for f in files():
    # This await provides backpressure so we don't keep posting jobs to the
    # queue while it is already stuffed! However, results may appear out-of-order
    # now since we print whatever job finishes first.
    await processSome()
    inflight.add pool.compute(f)

  for x in inflight:
    print(await x)

  pool[].close()

template timeIt(body: untyped) =
  let start = Moment.now()
  body
  echo astToStr(body), " ", (Moment.now() - start)
  echo "------------"
  echo ""

timeIt:
  readFilesSingle(makeTasks())

timeIt:
  readFilesThread(makeTasks())

timeIt:
  waitFor readFilesAsync(makeTasks())

timeIt:
  waitFor readFilesPool(makeTasks())

timeIt:
  waitFor readFilesMmap(makeTasks())

timeIt:
  waitFor readFilesBounded(makeTasks())
