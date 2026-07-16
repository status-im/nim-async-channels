{.push raises: [], gcsafe.}

import std/[atomics, locks, typetraits], chronos, results

export chronos, results

const asyncchannelsHints {.booldefine.} = true

type
  AsyncChannel*[TMsg] = object
    ## Async, unbounded MPMC channel suitable for usage with chronos' `async`
    ## event loop, similar to the built-in Nim `Channel`. This version of the
    ## channel is compatible with both `refc` and `orc`.
    ##
    ## Channel lifetime is controlled by `open` and `close` - before `close` is
    ## used, the caller is responsible for making sure that all work posted to
    ## the channel has been drained and that no threads are waiting for work, or
    ## memory leaks and crashes may happen.
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

    count: int

    lock: Lock
    data: ptr UncheckedArray[ptr Waiter[TMsg]]
    len, cap: int

  Waiter*[TMsg] = object
    ## Waiters are readers that arrived when there were no items in the queue -
    ## there is currently no fair ordering between waiters, ie a later arrival
    ## might steal items from an earlier waiter.
    tc: ptr AsyncChannel[TMsg]
    pdisp: PDispatcher
    fut: pointer

proc `=copy`[TMsg](v: var AsyncChannel[TMsg], b: AsyncChannel[TMsg]) {.error.}

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

  # It should not matter that the channel is created in shared memory (since it
  # does not interact with the GC at all) but just to be safe, let's do like the
  # documentation suggests and allocate it like so.
  tc.chan = createShared(typeof(tc.chan[]))
  tc.chan[].open(0)

  initLock tc.lock
  tc.len = 0
  tc.cap = 0
  tc.data = nil

  ok()

proc close*(tc: var AsyncChannel) =
  ## Release the resources used by the channel - before calling, ensure that no
  ## threads are waiting to send or receive data and that all related futures
  ## have are finished.
  if tc.chan == nil:
    return

  let chan = move tc.chan
  chan[].close()
  chan.deallocShared()

  if tc.len > 0:
    deallocShared tc.data

  deinitLock tc.lock

proc waiterAdd(tc: var AsyncChannel, w: ptr Waiter) =
  ## Add a Waiter into the shared data array. Reallocates capacity if needed.
  if tc.len >= tc.cap:
    # Grow by 2x, minimum initial cap of 8
    let newCap = max(tc.cap * 2, 8)
    let newData = cast[ptr UncheckedArray[ptr Waiter]](
      createSharedU(ptr Waiter, newCap))
    if tc.len > 0 and tc.data != nil:
      copyMem(addr newData[0], addr tc.data[0], tc.len * sizeof(Waiter))
      deallocShared tc.data
    tc.data = newData
    tc.cap = newCap

  tc.data[tc.len] = w
  inc tc.len

proc waiterRemove(tc: var AsyncChannel, v: var ptr Waiter): bool =
  ## Remove and return the last Waiter from the shared data array.
  if tc.len > 0:
    dec tc.len

    v = tc.data[tc.len]
    true
  else:
    false

proc deepCopyHint(T: typedesc) =
  when asyncchannelsHints and (not defined(gcDestructors)) and
      (not supportsCopyMem(T) or sizeof(T) > 64):
    {.
      hint: name(T) & " deep-copied - references are not preserved and copy may be slow"
    .}

proc recvImpl[TMsg](tc: ptr AsyncChannel[TMsg], fut: Future[TMsg]): bool =
  while tc[].count > 0:
    # `tryRecv` might fail due to contention so we need to keep trying until
    # there are no more items.
    let (dataAvailable, msg) = tc.chan[].tryRecv2()

    if dataAvailable:
      tc.count -= 1
      fut.complete(msg)
      return true

  false

proc recv*[TMsg](
    tc: ptr AsyncChannel[TMsg]
): Future[TMsg] {.async: (raises: [CancelledError], raw: true).} =
  ## Receive an item from the channel, waiting until one appears if none are
  ## currently available.
  ##
  ## Operation may be cancelled.
  ##
  ## Calling this function  on a channel that has not been opened or has already
  ## been closed is undefined behavior and may lead to panics or blocked threads.

  deepCopyHint(TMsg)

  let fut = newFuture[TMsg]("waiter")

  acquire tc[].lock
  defer:
    release tc[].lock

  if not tc.recvImpl(fut):
    var w = createShared(Waiter[TMsg])

    proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
      w.fut = nil

    fut.cancelCallback = cancellation

    w.tc = tc
    w.fut = cast[pointer](fut)
    w.pdisp = getThreadDispatcher()

    tc[].waiterAdd(w)

  fut

proc sendSync*[TMsg, U](tc: var AsyncChannel[TMsg], msg: sink U) =
  ## Send `msg` on the channel synchronously - this function may block when too
  ## many tasks have been posted to the channel and no consumer is there to
  ## process them - the limit is OS-dependent due to the cross-thread signalling
  ## mechanism used.
  ##
  ## Calling this function  on a channel that has not been opened or has already
  ## been closed is undefined behavior and may lead to panics or blocked threads.
  ##
  ## TODO https://github.com/status-im/nim-chronos/issues/604
  deepCopyHint(TMsg)

  acquire tc.lock
  defer:
    release tc.lock

  # Increase the counter before adding to the list
  tc.count += 1
  tc.chan[].send2(move(msg))

  while true:
    var w: ptr Waiter[TMsg]
    if not tc.waiterRemove(w):
      return # No waiters

    if w.fut == nil:
      deallocShared(w)
      continue # Waiter got cancelled

    # A waiter is available - wake up their dispatcher
    proc comp(udata: pointer) {.nimcall, gcsafe, raises: [].} =
      let w = cast[ptr Waiter[TMsg]](udata)
      if w.fut != nil:
        let
          fut = cast[Future[TMsg]](w.fut)
          tc = w.tc

        # Keep the lock while we check the queue so that `waiterAdd` doesn't
        # get interleaved with a concurrent `waiterRemove` that would say "no
        # waiters"

        acquire tc[].lock
        defer:
          release tc[].lock
        if w.tc.recvImpl(fut):
          deallocShared(w)
        else:
          # The item was stolen from us, try again later
          w.tc[].waiterAdd(w)

    w.pdisp.callSoon(comp, w)
    return # Waiter queued for processing
