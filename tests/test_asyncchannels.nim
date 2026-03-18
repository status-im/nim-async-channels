import ../asyncchannels, unittest2
import std/[os, atomics]

suite "AsyncChannels":
  test "Same thread, int":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    for i in 0 ..< 10:
      chan.sendSync(i)

    for i in 0 ..< 10:
      check:
        i == waitFor (addr chan).recv()

    chan.close()

  test "Same thread, string":
    var chan: AsyncChannel[string]
    chan.open().expect("can open channel")

    for i in 0 ..< 10:
      chan.sendSync($i)

    for i in 0 ..< 10:
      check:
        $i == waitFor (addr chan).recv()

    chan.close()

  test "SPSC, string":
    var chan: AsyncChannel[string]
    chan.open().expect("can open channel")

    proc fill(p: ptr AsyncChannel[string]) {.thread.} =
      for i in 0 ..< 10:
        p[].sendSync($i)

    var prod: Thread[ptr AsyncChannel[string]]
    prod.createThread(fill, addr chan)

    for i in 0 ..< 10:
      check:
        $i == waitFor (addr chan).recv()

    prod.joinThread()

  test "MPMC, string":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    var producers =
      newSeq[Thread[(ptr AsyncChannel[int], Moment, ptr Atomic[int])]](100)
    var consumers = newSeq[Thread[(ptr AsyncChannel[int], ptr Atomic[int])]](100)

    let start = Moment.now()

    var sump, sumc: Atomic[int]
    proc prod(p: (ptr AsyncChannel[int], Moment, ptr Atomic[int])) {.thread.} =
      var i = 0
      while Moment.now() < (p[1] + 500.millis):
        i += 1
        p[2][].atomicInc(i)
        p[0][].sendSync(i)

      p[0][].sendSync(0)

    proc cons(p: (ptr AsyncChannel[int], ptr Atomic[int])) {.thread.} =
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

  test "double open rejected":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    let res = chan.open()

    check:
      res.isErr()

    chan.close()

  test "close before open is no-op":
    var chan: AsyncChannel[int]

    chan.close()

    check:
      chan.open().isOk()

    chan.close()

  test "reopen after close rejected":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")
    chan.close()

    let res = chan.open()

    check:
      res.isErr()

  test "send after close asserts":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")
    chan.close()

    expect AssertionDefect:
      chan.sendSync(123)

  test "recv after close asserts":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")
    chan.close()

    expect AssertionDefect:
      discard waitFor (addr chan).recv()

  test "blocked recv wakes during close":
    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    proc closer(p: ptr AsyncChannel[int]) {.thread.} =
      sleep(50)
      p[].close()

    var closingThread: Thread[ptr AsyncChannel[int]]
    createThread(closingThread, closer, addr chan)

    expect AssertionDefect:
      discard waitFor (addr chan).recv()

    closingThread.joinThread()

  test "stress repeated blocked recv close race":
    for _ in 0 ..< 200:
      var chan: AsyncChannel[int]
      chan.open().expect("can open channel")

      proc closer(p: ptr AsyncChannel[int]) {.thread.} =
        sleep(1)
        p[].close()

      var closingThread: Thread[ptr AsyncChannel[int]]
      createThread(closingThread, closer, addr chan)

      expect AssertionDefect:
        discard waitFor (addr chan).recv()

      closingThread.joinThread()

  test "stress many blocked receivers wake during close":
    const waiters = 16

    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    var awakened: Atomic[int]
    var consumers = newSeq[Thread[(ptr AsyncChannel[int], ptr Atomic[int])]](waiters)

    proc cons(p: (ptr AsyncChannel[int], ptr Atomic[int])) {.thread.} =
      try:
        discard waitFor p[0].recv()
        doAssert false, "recv unexpectedly succeeded"
      except AssertionDefect:
        p[1][].atomicInc()

    for consumer in consumers.mitems():
      createThread(consumer, cons, (addr chan, addr awakened))

    sleep(20)
    chan.close()

    for consumer in consumers.mitems():
      consumer.joinThread()

    check:
      awakened.load() == waiters

  test "stress many concurrent closers":
    const closers = 16

    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    var awakened: Atomic[int]
    var recvThread: Thread[(ptr AsyncChannel[int], ptr Atomic[int])]
    var closingThreads = newSeq[Thread[ptr AsyncChannel[int]]](closers)

    proc blockedRecv(p: (ptr AsyncChannel[int], ptr Atomic[int])) {.thread.} =
      try:
        discard waitFor p[0].recv()
        doAssert false, "recv unexpectedly succeeded"
      except AssertionDefect:
        p[1][].atomicInc()

    proc doClose(p: ptr AsyncChannel[int]) {.thread.} =
      p[].close()

    createThread(recvThread, blockedRecv, (addr chan, addr awakened))

    sleep(20)

    for closingThread in closingThreads.mitems():
      createThread(closingThread, doClose, addr chan)

    for closingThread in closingThreads.mitems():
      closingThread.joinThread()

    recvThread.joinThread()

    check:
      awakened.load() == 1

  test "stress mixed send recv close":
    const producers = 8
    const consumers = 8

    var chan: AsyncChannel[int]
    chan.open().expect("can open channel")

    var sendsOk, sendsClosed, recvsOk, recvsClosed: Atomic[int]
    var producerThreads = newSeq[
      Thread[(ptr AsyncChannel[int], ptr Atomic[int], ptr Atomic[int])]
    ](producers)
    var consumerThreads = newSeq[
      Thread[(ptr AsyncChannel[int], ptr Atomic[int], ptr Atomic[int])]
    ](consumers)

    proc prod(p: (ptr AsyncChannel[int], ptr Atomic[int], ptr Atomic[int])) {.thread.} =
      for i in 0 ..< 5000:
        try:
          p[0][].sendSync(i)
          p[1][].atomicInc()
        except AssertionDefect:
          p[2][].atomicInc()
          return

    proc cons(p: (ptr AsyncChannel[int], ptr Atomic[int], ptr Atomic[int])) {.thread.} =
      while true:
        try:
          discard waitFor p[0].recv()
          p[1][].atomicInc()
        except AssertionDefect:
          p[2][].atomicInc()
          return

    for producer in producerThreads.mitems():
      createThread(producer, prod, (addr chan, addr sendsOk, addr sendsClosed))

    for consumer in consumerThreads.mitems():
      createThread(consumer, cons, (addr chan, addr recvsOk, addr recvsClosed))

    sleep(20)
    chan.close()

    for producer in producerThreads.mitems():
      producer.joinThread()

    for consumer in consumerThreads.mitems():
      consumer.joinThread()

    check:
      sendsOk.load() + sendsClosed.load() > 0
      recvsOk.load() + recvsClosed.load() > 0
      recvsClosed.load() == consumers
