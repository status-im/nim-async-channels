import std/atomics, ../asyncchannels, unittest2

suite "AsyncChannel":
  test "Same thread, int":
    var chan: AsyncChannel[int]
    chan.init()

    for i in 0 ..< 10:
      chan.send(i)

    for i in 0 ..< 10:
      check:
        i == waitFor((addr chan).recv())

    chan.destroy()

  test "Same thread, string":
    var chan: AsyncChannel[string]
    chan.init()

    for i in 0 ..< 10:
      chan.send($i)

    for i in 0 ..< 10:
      check:
        $i == waitFor((addr chan).recv())

    chan.destroy()

  test "SPSC, string":
    var chan: AsyncChannel[string]
    chan.init()

    proc fill(p: ptr AsyncChannel[string]) {.thread, gcsafe, nimcall.} =
      for i in 0 ..< 10:
        p[].send($i)

    var prod: Thread[ptr AsyncChannel[string]]
    prod.createThread(fill, addr chan)

    for i in 0 ..< 10:
      check:
        $i == waitFor((addr chan).recv())

    prod.joinThread()
    chan.destroy()

  test "MPMC, string":
    var chan: AsyncChannel[int]
    chan.init()

    var producers =
      newSeq[Thread[(ptr AsyncChannel[int], Moment, ptr Atomic[int])]](100)
    var consumers = newSeq[Thread[(ptr AsyncChannel[int], ptr Atomic[int])]](100)

    let start = Moment.now()

    var sump, sumc: Atomic[int]
    proc prod(
        p: (ptr AsyncChannel[int], Moment, ptr Atomic[int])
    ) {.thread, gcsafe, nimcall.} =
      var i = 0
      while Moment.now() < (p[1] + 500.millis):
        i += 1
        p[2][].atomicInc(i)
        p[0][].send(i)

      p[0][].send(0)

    proc cons(p: (ptr AsyncChannel[int], ptr Atomic[int])) {.thread, gcsafe, nimcall.} =
      while true:
        let i = waitFor p[0].recv()
        if i == 0:
          return
        p[1][].atomicInc(i)

    for p in producers.mitems():
      createThread(p, prod, (addr chan, start, addr sump))

    for p in consumers.mitems():
      createThread(p, cons, (addr chan, addr sumc))

    for p in producers.mitems():
      p.joinThread()

    for p in consumers.mitems():
      p.joinThread()

    check:
      sump == sumc

    chan.destroy()

  test "close after send delivers both item and close signal":
    var chan: AsyncChannel[int]
    chan.init()

    chan.send(42)
    chan.send(100)
    chan.close()

    check:
      waitFor((addr chan).recv()) == 42
    check:
      waitFor((addr chan).recv()) == 100
    # After close, recv should return default
    check:
      waitFor((addr chan).recv()) == 0

    chan.destroy()

  test "cancellation before queueing (item already available)":
    var chan: AsyncChannel[int]
    chan.init()

    chan.send(99)

    var fut = (addr chan).recv()
    # recv returns immediately (no waiter queued) - cancel is noop
    waitFor fut.cancelAndWait()
    check:
      waitFor(fut) == 99

    chan.destroy()

  test "cancellation after queueing before send":
    var chan: AsyncChannel[int]
    chan.init()

    # Reader queues a waiter
    var fut = (addr chan).recv()

    # Cancel the future
    waitFor fut.cancelAndWait()

    # Channel is still alive, can send
    chan.send(1)

    # But the future was already cancelled
    expect(CancelledError):
      discard waitFor(fut)

    # Destroy the channel with futures in it
    chan.close()
    chan.destroy()

  test "close wakes readers that haven't awaited yet":
    var chan: AsyncChannel[int]
    chan.init()

    # Start a reader but don't await immediately
    var fut = (addr chan).recv()

    # Close — this should complete the waiter with default
    chan.close()

    check:
      waitFor(fut) == 0

    chan.destroy()

  test "items might get stolen":
    var chan: AsyncChannel[int]
    chan.init()

    # Start a reader but don't await immediately
    var fut = (addr chan).recv()

    chan.send(42) # Wakes the queued recv

    # ...however, since the event loop is not working, another recv will
    # steal the item!
    var fut2 = (addr chan).recv()
    check:
      fut2.finished()

    waitFor sleepAsync(1.millis) # run the loop for a bit

    check:
      not fut.finished() # Still queued

    chan.send(43) # we should not have lost the recv

    check:
      waitFor(fut) == 43

    chan.destroy()

  test "cancellation with inflight waiter":
    var chan: AsyncChannel[int]
    chan.init()

    # Start a reader but don't await immediately
    var
      fut = (addr chan).recv()
      fut2 = (addr chan).recv()

    chan.send(42) # Wakes the queued recv
    waitFor fut.cancelAndWait() # The first future is cancelled

    expect(CancelledError):
      discard waitFor(fut)

    check:
      waitFor(fut2) == 42 # Fut2 should get the item

    chan.destroy()
