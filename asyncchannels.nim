{.push raises: [], gcsafe.}

import std/[atomics, locks, typetraits], chronos, results

export chronos, results

const asyncchannelsHints {.booldefine.} = true

when (defined(gcArc) or defined(gcOrc) or defined(gcAtomicArc)) and
    not defined(useMalloc) and not defined(asyncchannelsYolo):
  {.
    error:
      "https://github.com/nim-lang/Nim/issues/26014: Use `-d:useMalloc` or `-d:asyncchannelsYolo`"
  .}

type
  AsyncChannel*[TMsg] = object
    ## Unbounded MPMC channel suitable for bridging threads to chronos' `async`
    ## event loop`.
    ##
    ## The sender side may be any thread (chronos or not).
    ##
    ## The receiver side must be a `chronos` event loop - wakeup notifications
    ## are posted to the event loop owning the reader.
    ##
    ## The channel is compatible with both `refc` and `orc`.
    ##
    ## Channel lifetime is controlled by `init` and `destroy` - before `init`
    ## and after `destroy`, no thread may access the channel - in particular,
    ## readers must not be queued. To wake readers before `destroy`, the writing
    ## side can be closed with `close`.
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
    ## use cases where disk/process I/O is involved.
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
    ## hood and `AsyncChannel` inherits its performance profile and quirks that
    ## manifest when using `refc`:
    ##
    ## * Items added to the channel are deep-copied inside a lock - this means
    ##   that the channel is unsuitable for large items or high-contention producers
    ## * Items received from the channel are similarly copied - this means that
    ##   at a _minimum_, two copies of the item will be performed - keep the items
    ##   small!
    ## * Thread wake-up is done using chronos' `callSoon` mechanism - if
    ##   the event loop is busy or not working, items will not be cleared from
    ##   the queue
    ## * Async operations on the sending side are currently not supported.
    ## * Given the unbounded nature of the channel itself, the producer must
    ##   manage backpressure.
    ##
    ## Future versions may use a different channel / serialization method and
    ## thus some of these properties may change (but it certainly can't get worse
    ## than this!) - in particular, with `ORC` we can reduce the amount of copying
    ## done and therefore lift several of the restrictions highlighted above.
    lock: Lock

    chan*: ptr Channel[TMsg]
      # TODO We use a nim channel here to get to the object serialization it
      #      implements - convenient but carries some unnecessary overhead since
      #      for some reason, `Channel` holds a lock while performing the copy

    count: int
    closed: bool

    whead, wtail: ptr Waiter[TMsg]

  Waiter*[TMsg] = object
    ## Waiters are readers that arrived when there were no items in the queue.
    ##
    ## Waiters get notified via `callSoon` when an item arrives - when there are
    ## multiple dispatchers (ie multiple event loops/threads), work may be
    ## stolen by another thread while the waiter is waking up.
    ##
    ## Stopping the dispatcher without cancelling its waiter causes undefined
    ## behavior for the queue.
    tc: ptr AsyncChannel[TMsg]
    disp: DispatcherHandle
    fut: pointer
    next: ptr Waiter[TMsg]

# AsyncChannel pointers must remain stable
proc `=copy`[TMsg](v: var AsyncChannel[TMsg], b: AsyncChannel[TMsg]) {.error.}

# TODO https://github.com/nim-lang/Nim/issues/26071
# proc `=sink`[TMsg](v: var AsyncChannel[TMsg], b: AsyncChannel[TMsg]) {.error.}

# TODO https://github.com/nim-lang/Nim/pull/25318
template tryRecv2*(c: var Channel): untyped =
  {.cast(raises: []).}:
    c.tryRecv()

template send2*(c: var Channel, msg: auto) =
  {.cast(raises: []).}:
    c.send(msg)

proc pushWaiter[TMsg](tc: var AsyncChannel[TMsg], w: ptr Waiter[TMsg]) =
  ## Add a Waiter to the tail of the intrusive linked list (FIFO).
  w.next = nil
  if tc.wtail != nil:
    tc.wtail.next = w
  else:
    tc.whead = w
  tc.wtail = w

proc popWaiter[TMsg](tc: var AsyncChannel[TMsg]): ptr Waiter[TMsg] =
  ## Remove and return the head Waiter from the intrusive linked list.
  ## Skips cancelled waiters (w.fut == nil) and deallocates their node.
  while tc.whead != nil:
    let w = tc.whead
    if w.fut != nil:
      tc.whead = w.next
      if tc.whead == nil:
        tc.wtail = nil
      return w

    # Cancelled waiter — skip and dealloc
    tc.whead = w.next
    if tc.whead == nil:
      tc.wtail = nil

    deallocShared(w)

proc deepCopyHint(T: typedesc) =
  when asyncchannelsHints and (not defined(gcDestructors)) and
      (not supportsCopyMem(T) or sizeof(T) > 64):
    when (NimMajor, NimMinor) >= (2, 2):
      {.hint: $T & " deep-copied - references are not preserved and copy may be slow".}

proc recvImpl[TMsg](tc: var AsyncChannel[TMsg], fut: Future[TMsg]): bool =
  while tc.count > 0:
    # `tryRecv` technically can fail under contention - however, because we are
    # inside our lock, this shouldn't happen but we add a loop anyway for
    # robustness

    var (dataAvailable, msg) = tc.chan[].tryRecv2()

    if dataAvailable:
      tc.count -= 1
      fut.complete(move(msg))
      return true

  if tc.closed:
    fut.complete(default(TMsg))
    return true

  false

proc completeWaiter[TMsg](udata: pointer) {.nimcall.}

proc schedule[TMsg](w: ptr Waiter[TMsg]) =
  if not w.isNil:
    w.disp.callSoon(completeWaiter[TMsg], w)

proc completeWaiter[TMsg](udata: pointer) {.nimcall.} =
  let
    w = cast[ptr Waiter[TMsg]](udata)
    tc = w.tc

  if w.fut.isNil:
    # Cancelled while waiting in "callSoon" - wake up the next waiter if any
    let next = block:
      acquire tc[].lock
      defer:
        release tc[].lock
      tc[].popWaiter()
    next.schedule()
  else:
    let fut = cast[Future[TMsg]](move(w.fut))

    # Keep the lock while we check the queue so that `pushWaiter` doesn't
    # get interleaved with a concurrent `popWaiter` that would say "no
    # waiters"
    block:
      acquire tc[].lock
      defer:
        release tc[].lock

      if not tc[].recvImpl(fut):
        # The item was stolen from us, try again later
        w.fut = cast[pointer](addr fut[])
        tc[].pushWaiter(w)
        return

    GC_unref(fut)

  deallocShared(w)

proc init*(tc: var AsyncChannel) =
  ## Initialize a channel instance.
  ##
  ## - `init` must be called before using the channel
  ## - use `destroy` to release it.

  # It should not matter that the channel is created in shared memory (since it
  # does not interact with the GC at all) but just to be safe let's do like the
  # documentation suggests and allocate it like so.
  doAssert tc.chan.isNil, "Can only re-init a destroyed channel"

  tc.chan = createShared(typeof(tc.chan[]))
  tc.chan[].open(0)

  initLock tc.lock
  tc.whead = nil
  tc.wtail = nil
  tc.count = 0
  tc.closed = false

proc destroy*(tc: var AsyncChannel) =
  ## Release the resources used by the channel.
  ##
  ## `destroy` is not thread-safe - it is the responsibility of the caller to
  ## ensure that no readers and writers are accessing the channel.
  ##
  ## Use `close` to close the channel prior to destroying it - this will wake
  ## all pending readers allowing them to gracefully shut down.
  if tc.chan.isNil():
    return

  # destroy means the channel is cleared of queued items
  let chan = move tc.chan
  chan[].close()
  chan.deallocShared()
  tc.count = 0

  doAssert tc.popWaiter().isNil(), "Readers found during `destroy`"

  deinitLock tc.lock

proc close*[TMsg](tc: var AsyncChannel[TMsg]) =
  ## Close the channel for writing and complete any pending readers with
  ## default(TMsg). Already-queued messages are delivered as usual but calling
  ## `send` after `close` is not allowed.
  var waiters: seq[ptr Waiter[TMsg]]
  block:
    acquire tc.lock

    defer:
      release tc.lock

    # Mark the channel as closed so that recvImpl will complete waiters with default
    tc.closed = true

    # Wake all current waiters - they will be completed with a `default(T)`
    # value
    var w = tc.popWaiter()
    while not w.isNil:
      waiters.add w
      w = tc.popWaiter()

  for w in waiters:
    w.schedule()

proc recv*[TMsg](
    tc: ptr AsyncChannel[TMsg]
): Future[TMsg] {.async: (raises: [CancelledError], raw: true).} =
  ## Receive an item from the channel, waiting until one appears if none are
  ## currently available.
  ##
  ## If the channel is or gets closed, a default-initialized item will be
  ## returned.
  ##
  ## Operation may be cancelled.

  deepCopyHint(TMsg)
  doAssert not tc.chan.isNil, "Channel not initialized"

  let fut = newFuture[TMsg]("waiter")

  acquire tc[].lock
  defer:
    release tc[].lock

  if not tc[].recvImpl(fut):
    let w = createShared(Waiter[TMsg])

    proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
      if w.fut == nil: # Already processed
        return

      let
        fut = cast[Future[TMsg]](move(w.fut))
        tc = w.tc

      # We can release the future here but the waiter itself will be freed
      # by one of `completeWaiter` and `popWaiter`.
      GC_unref(fut)

      # Schedule another waiter, if there is any queued
      let next = block:
        acquire tc[].lock
        defer:
          release tc[].lock
        tc[].popWaiter()

      next.schedule()

    fut.cancelCallback = cancellation

    # Waiter does not get traced so we must ensure the future does not get
    # collected manually
    GC_ref(fut)

    w.tc = tc
    w.fut = cast[pointer](fut)
    w.next = nil
    w.disp = getThreadDispatcher().handle()

    tc[].pushWaiter(w)

  fut

proc send*[TMsg, U](tc: var AsyncChannel[TMsg], msg: sink U) =
  ## Send `msg` on the channel. As the channel is unbounded, this function will
  ## never block.
  ##
  ## The caller is responsible for managing backpressure.
  ##
  ## Calling this function on a channel that has not been opened or has already
  ## been closed is undefined behavior and may lead to panics or blocked threads.
  ##
  ## TODO https://github.com/status-im/nim-chronos/issues/604
  deepCopyHint(TMsg)

  doAssert not tc.chan.isNil, "Channel not initialized"

  let w = block:
    acquire tc.lock
    defer:
      release tc.lock

    doAssert not tc.closed, "Channel closed"

    tc.count += 1
    tc.chan[].send2(move(msg))

    tc.popWaiter()

  # A waiter is available - wake their dispatcher and hope it's still working
  w.schedule()
