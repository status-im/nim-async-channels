# asyncchannels

Unbounded MPMC channel for usage with [chronos](https://github.com/status-im/nim-chronos/)'
`async` event loop, similar to the built-in Nim [`Channel`](https://nim-lang.org/docs/system.html#Channel).

The channel is suitable for small to moderately sized messages with relaxed
latency requirements.

See the [source code](./asyncchannels.nim) for documentation and more information.

Key implementation details:

- Copies: In `refc`, items are deep-copied by the underlying `Channel` while
  holding a lock. Keep messages small or pass handles to off-channel buffers.
- open/close: open allocates signaling resources (can fail), close must be
  called once the channel is drained and no tasks are waiting.
- Chronos-only wakeups: `AsyncChannel` can wake `chronos`-managed threads/tasks.
  It cannot wake non-`chronos` threads — use plain `Channel` for that direction.
- GC compatibility: the channel works with `refc` and `orc` but your payload may
  not: prefer manually managed memory and off-channel buffers.
- Internals: Wraps a Nim `Channel[T]` and uses `chronos`' `ThreadSignalPtr` to
  wake the consumer event loop.

## Getting started

Install `asyncchannels` using `nimble`:

Nimble:
```nim
requires "https://github.com/status-im/nim-async-channels"
```

test.nim:
```nim
import asyncchannels

var chan: AsyncChannel[string]

proc fill(p: ptr AsyncChannel[string]) {.thread.} =
  for i in 0 ..< 10:
    p[].sendSync($i)
  p[].sendSync("")

proc main(chan: ptr AsyncChannel[string]) {.async.} =
  chan[].open().expect("can open channel")

  var prod: Thread[ptr AsyncChannel[string]]
  prod.createThread(fill, chan)

  while true:
    let str = await chan.recv()
    if str.len == 0: # sentinel
      break
    echo str

  prod.joinThread()
  chan[].close()

waitFor main(addr chan)
```

Getting started checklist:

- Small messages / control or handles: Post small structs/ids/handles on the channel; store payloads in shared memory (see examples/sharedbuf.nim).
- Sentinel/Opt pattern: Use `Opt[T]` or a sentinel value to signal shutdown.
- Backpressure: Use bounded producers or limit inflight tasks on the producer side to avoid unbounded memory growth
- MPSC usage: Prefer a single consumer thread (the Chronos loop that created the channel). While multiple consumers work, the common pattern is MPSC with one event-loop consumer.
- Fine-grained tasks: For many tiny tasks, prefer taskpools (e.g. nim-taskpools) and post only final results to channels.


## Examples

See the [examples](./examples/) folder for ways to structure channel usage for
a variety of use cases such as thread pools and work pipelines involving large
file I/O and computation.

## Chronos and threading

Channels allow posting work between threads using a thread-safe queue along
with a means of discovery for the other thread to know that work has been
posted.

In its most simple form, the discovery mechanism might be based on polling, but
most channels instead use a cross-thread notification mechanism that efficiently
wakes up the target thread if it's sleeping and lets it know that new content is
available.

When using `chronos`, the `chronos` event dispatcher is used to coordinate work
cooperatively between asynchronous tasks on a single thread, with each thread
having its own dispatcher.

`AsyncChannel` thus uses chronos' native task multiplexing support to allow
tasks to wake up the event dispatcher as items arrive on the channel.

`AsyncChannel` can be used with different sources:

* native Nim threads, potentially reading tasks from `Channel`
* `chronos` event loop threads
* thread pools such as [`taskpools`](https://github.com/status-im/nim-taskpools/)
* FFI, such as when integrating `chronos` with a foreign scheduler

`AsyncChannel` can not wake non-chronos threads and therefore cannot be used for
posting work to threads that are not managed by `chronos` - when posting work to
such threads, use a channel implementation suitable for that environment:

* native Nim threads: `Channel`
* Qt GUI: [`signals` and `slots`](https://doc.qt.io/qt-6/threads-qobject.html#signals-and-slots-across-threads)

## Thread safety and garbage collection

In order to stay compatible with `refc`, garbage-collected types (`ref`,
`string,`, `seq` and closures) must be deep-copied when crossing thread boundaries.

This copy may be expensive to perform within the the channel - an alternative
technique is to use unmanaged memory and only pass pointer/size pairs on the
channel, releasing memory manually when the task is finished.

Unamanged memory can be allocated either using the Nim memory manager (
[`createSharedU`](https://nim-lang.org/docs/system.html#createSharedU%2Ctypedesc),
[`deallocShared`](https://nim-lang.org/docs/system.html#deallocShared%2Cpointer))
or the `C` library (`malloc`, `free`).

See see [`sharedbuf`](./examples/utils/sharedbuf.nim) which uses a simple
`malloc`-based allocator.

The `malloc`-based allocator is particular in that it returns memory to the
operating system, unlike `createShared` which recycles it.

## Documentation

Documentation is available in the [implementation](./asyncchannels.nim) itself.

## Contributing

Contributions are welcome - if unsure, feel free to post an issue first!

`asyncchannels` follows the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/) and the code is formatted using [nph](https://github.com/arnetheduck/nph).

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
