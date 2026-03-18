{.push raises: [], gcsafe.}

import std/typetraits, std/atomics, std/os, chronos, chronos/threadsync, results

export chronos, threadsync, results

const asyncchannelsHints {.booldefine.} = true

# Packed state layout: bit 0 means "open", bit 1 means "closing", and the
# remaining high bits store the number of in-flight send/recv operations.
# Each active operation adds/subtracts `asyncChannelRefUnit`, leaving the flag
# bits untouched while `close` waits for the count to drain to zero.
const
  asyncChannelOpenBit = 1'u
  asyncChannelClosingBit = 2'u
  asyncChannelRefShift = 2
  asyncChannelRefUnit = 1'u shl asyncChannelRefShift

type AsyncChannel*[TMsg] = object
  ## Async, unbounded MPMC channel suitable for usage with chronos' `async`
  ## event loop, similar to the built-in Nim `Channel`. This version of the
  ## channel is compatible with both `refc` and `orc`.
  ##
  ## Channel lifetime is controlled by `open` and `close` - before `close` is
  ## used, the caller is responsible for making sure that all work posted to
  ## the channel has been drained if it matters. Once `close` starts, new
  ## operations are rejected and the call waits for in-flight `recv` and
  ## `sendSync` operations to leave the shared state before freeing resources.
  ##
  ## Performance-wise, the channel is suitable for use cases where tasks are:
  ##
  ## * relatively large - tens of milliseconds or more to process the data
  ## * not so numerous - a rate not exceeding the low hundreds per second
  ## * limited contention per channel (tens of threads, not thousands)
  ## * limited object sizes - in the hundreds of bytes (actual I/O payloads
  ##   do not need to go on the channel!)
  ##
  ## Although these limitations may seem onerous, they match most real-world
  ## use cases where I/O is involved.
  ##
  ## When dealing with large payloads, handles to shared memory (or files)
  ## should be used, rather than posting the payload itself.
  ##
  ## If tasks are smaller, `nim-taskpools` provides more granular and efficient
  ## task scheduling - fine-grained tasks can then be scheduled to taskpools with
  ## only the final result posted to the Channel.
  ##
  ## Implementation notes:
  ##
  ## In order to stay compatible with `refc`, a nim `Channel` is used under the
  ## hood and `AsyncChannel` inherits its performance profile and quirks, that
  ## manifest when using `refc`:
  ##
  ## * Items added to the channel are deep-copied inside a lock - this means
  ##   that the channel is unsuitable for large items or high-contention producers
  ## * Items received from the channel are similarly copied - this means that
  ##   at a _minimum_, two copies of the item will be performed - keep the items
  ##   small!
  ## * All item copying is done while holding a per-channel lock - this limits
  ##   producer concurrency, specially when trying to push large items.
  ## * chronos' ThreadSignalPtr is used under the hood which in turn relies on
  ##   OS primitives for wakeup and synchronization - these are not the fastest
  ##   out there, ie the time between pushing an item and a thread waking up
  ##   to process it may be significant depending on the load on the processing
  ##   thread and other factors.
  ## * Although an AsyncChannel can be shared between multiple consumer threads,
  ##   the recommended way of using it is in an MPSC setting where only the
  ##   thread that created the channel consumes data from it. YMMV if you use it
  ##   in any other way.
  ## * Async operations on the sending side are currently not supported.
  ##
  ## Future versions may use a different channel / serialization method and
  ## thus some of these properties may change (but it certainly can't get worse
  ## than this!) - in particular, with `ORC` we can reduce the amount of copying
  ## done and therefore lift several of the restrictions highlighted above.
  chan*: ptr Channel[TMsg]
    # TODO We use a nim channel here to get to the object serialization it
    #      implements - convenient but carries some unnecessary overhead since
    #      for some reason, `Channel` holds a lock while performing the copy

  sig: ThreadSignalPtr
  state: Atomic[uint]

template activeOps(state: uint): uint =
  state shr asyncChannelRefShift

proc misuse(op: static string) {.noreturn, noinline.} =
  raiseAssert "AsyncChannel." & op & " on a channel that is not open"

proc beginOp[T](tc: ptr AsyncChannel[T]): bool =
  while true:
    var state = tc.state.load(moAcquire)

    if (state and asyncChannelOpenBit) == 0 or
        (state and asyncChannelClosingBit) != 0:
      return false

    let desired = state + asyncChannelRefUnit
    if tc.state.compareExchange(state, desired, moAcquireRelease, moAcquire):
      return true

proc endOp[T](tc: ptr AsyncChannel[T]) {.inline.} =
  discard tc.state.fetchSub(asyncChannelRefUnit, moAcquireRelease)

# TODO https://github.com/nim-lang/Nim/pull/25318
template tryRecv2*(c: var Channel): untyped =
  {.cast(raises: []).}:
    c.tryRecv()

template send2*(c: var Channel, msg: auto) =
  {.cast(raises: []).}:
    c.send(msg)

proc open*(tc: var AsyncChannel): Result[void, string] =
  ## Prepare the channel for writing - open can fail if therer are not enough
  ## system resources (file descriptors) for the signalling mechanism.
  if tc.state.load(moAcquire) != 0:
    return err("AsyncChannel.open on a channel that is already open or closed")

  tc.sig = ?ThreadSignalPtr.new()
  # It should not matter that the channel is created in shared memory (since it
  # does not interact with the GC at all) but just to be safe, let's do like the
  # documentation suggests and allocate it like so.
  tc.chan = createShared(typeof(tc.chan[]))
  tc.chan[].open(0)
  tc.state.store(asyncChannelOpenBit, moRelease)

  ok()

proc close*(tc: var AsyncChannel) =
  ## Release the resources used by the chanel.
  ##
  ## Once `close` starts, new operations are rejected and blocked receivers are
  ## woken up until all in-flight operations have left the shared state.
  while true:
    var state = tc.state.load(moAcquire)

    if (state and asyncChannelOpenBit) == 0 or
        (state and asyncChannelClosingBit) != 0:
      return

    let desired = state or asyncChannelClosingBit
    if tc.state.compareExchange(state, desired, moAcquireRelease, moAcquire):
      break

  while true:
    discard tc.sig.fireSync()

    if tc.state.load(moAcquire).activeOps == 0:
      break

    sleep(1)

  discard tc.sig.close()
  reset tc.sig

  tc.chan[].close()
  tc.chan.deallocShared()

  reset tc.chan
  tc.state.store(asyncChannelClosingBit, moRelease)

template deepCopyHint(T: typedesc) =
  when asyncchannelsHints and (not defined(gcDestructors)) and
      (not supportsCopyMem(T) or sizeof(T) > 64):
    {.
      hint: name(T) & " deep-copied - references are not preserved and copy may be slow"
    .}

proc recv*[T](
    tc: ptr AsyncChannel[T]
): Future[T] {.async: (raises: [CancelledError]).} =
  ## Receive an item from the channel, waiting until one appears if none are
  ## currently available.
  ##
  ## Operation may be cancelled.
  ##
  ## Calling this function on a channel that has not been opened yet or that is
  ## closing raises an assertion defect.

  deepCopyHint(T)

  if not tc.beginOp():
    misuse("recv")
  defer:
    tc.endOp()

  while true:
    if (tc.state.load(moAcquire) and asyncChannelClosingBit) != 0:
      misuse("recv")

    let (dataAvailable, msg) = tc.chan[].tryRecv2()

    if dataAvailable:
      if tc.chan[].peek > 0:
        # Depending on the OS, ThreadSignalPtr will wake up only one thread even
        # though `fire` has been called multiple times - if there are still
        # items in the queue at this stage, schedule another thread to work on
        # them.
        # This trick also solves a race condition where other threads might get
        # stuck during shutdown, if a single thread swallows the wake-up
        # notification for multiple "shutdown" markers being posted to the
        # channel.
        # The downside of this approach is that it leads to spurious wake-ups
        # and a bit of overhead.
        discard tc.sig.fireSync()
      return msg

    try:
      await tc.sig.wait()
    except AsyncError as exc:
      if (tc.state.load(moAcquire) and asyncChannelClosingBit) != 0:
        misuse("recv")
      raiseAssert exc.msg

proc sendSync*[T, U](tc: var AsyncChannel[T], msg: sink U) =
  ## Send `msg` on the channel synchronously - this function may block when too
  ## many tasks have been posted to the channel and no consumer is there to
  ## process them - the limit is OS-dependent due to the cross-thread signalling
  ## mechanism used.
  ##
  ## Calling this function on a channel that has not been opened yet or that is
  ## closing raises an assertion defect.
  ##
  ## TODO https://github.com/status-im/nim-chronos/issues/604
  deepCopyHint(T)

  if not (addr tc).beginOp():
    misuse("sendSync")
  defer:
    (addr tc).endOp()

  tc.chan[].send2(move(msg))
  # Reader will fire in case we need another notification
  discard tc.sig.fireSync()
