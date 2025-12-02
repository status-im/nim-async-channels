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
