# Ivy in JavaScript

The shell around `IvyCore` for a browser or Node 22+: the core runs as a
WebAssembly module and this package drives it. It is the counterpart of
`Sources/Ivy`, and like it decides nothing: events go in, effects come out.

```text
application: delegate, content source, transports
                    |
shell.ts: connections, one timer, requests as promises
                    |   encoded events in, encoded effects out
core.ts -> ivy.wasm (Sources/IvyWasm, around IvyCore.step)
```

Not here yet: WebSocket and WebRTC transports, signalling and storage. They
plug into `Transport` and `ContentSource`.

## Build and test

Needs a swift.org toolchain with its matching Wasm SDK (not Xcode's) and
Node 22 or later.

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh   # dist/ivy.wasm and dist/**/*.js
cd Web && npm test
```

Set `SWIFT` to run a particular toolchain, for example
`SWIFT="swiftly run +6.4.1 swift"`. `Wasm/run.sh` does both of the above after
its own checks. The tests run against the real module; `IVY_WASM` points them
at another build of it.

## The demo page

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh
cd Web && npm run serve
```

Open `http://localhost:8000/demo/` (`PORT` changes the port). The page starts
two nodes, joins them with an in-memory stream, exchanges messages, fetches a
20 MiB Volume through a stream that fills at 256 KiB, and writes `PASS`, or
`FAIL` and the reason, at the top.

## Use

```ts
import { Ivy, IvyModule } from './dist/src/index.js';

const module = await IvyModule.load(await (await fetch('ivy.wasm')).arrayBuffer());
const ivy = new Ivy(module, { signingKey: seed, listenPort: 0 }, {
  delegate: {
    async peerConnected(peer) {},
    async deliver(message, from) {},
  },
  contentSource: { volume: async (rootCID) => entries(rootCID) },
});
await ivy.start();

ivy.accept(inboundTransport);                    // this node responds
await ivy.connect(endpoint, outboundTransport);  // this node initiates
await ivy.sendMessage(endpoint.publicKey, 'sync', payload);
const volume = await ivy.fetchVolume(rootCID, { signal });
await ivy.stop();
```

One module instance holds any number of nodes. `destroy()` frees a node's core.

The methods are the native `Ivy` actor's, with these differences:

- Everything the core answers is a promise, `sendMessage` included.
- A request takes an `AbortSignal` where the native one is cancelled with its
  task. Aborting completes it as the core answers a cancelled request: an
  empty Volume, `false`, or `connect` rejecting with `IvyError('cancelled')`.
- `fetchVolume` takes its session and limits as options.
- There is no listener and no STUN. Streams are handed in with `accept` and
  `connect`, the core's own dials go to the `dial` option, and
  `reportPublicAddress` tells the core an address learned elsewhere.
- There is no admission lease: the core admits or closes an accepted stream
  by its connection and netgroup limits, and events are applied as they are
  made, so nothing queues ahead of it.
- Traffic is not recorded in a Tally ledger, which keeps its own clock; peers
  waiting for a serving slot are served in turn.

## Writing a transport

`Transport` (`src/transport.ts`) is `TransportConnection` in TypeScript: an
ordered, reliable byte stream that

- reports the host its peer was observed at, which admission needs;
- delivers bytes only when asked, one `received` for each `requestBytes`;
- queues whatever it is sent, and says through `isWritable` and `drained`
  when to stop and when to go on;
- reports its close exactly once.

The shell asks for the next bytes only after the core has handled the last,
and not at all while the core is holding the connection: a record with the
delegate, an exhausted byte budget. A transport that cannot stop its peer,
as a WebSocket cannot, buffers what arrives in between and should close when
that buffer is larger than it will hold.

`memoryPair` (`src/memory.ts`) is a complete example.

## The module's interface

`Sources/IvyWasm/main.swift` exports a small C ABI; `src/core.ts` is its only
caller. Events, effects and the configuration cross it as
[docs/event-codec.md](../docs/event-codec.md) encodes them, and
`test/vectors.json` pins that encoding for both sides.

| Export | |
| --- | --- |
| `ivy_alloc(length)`, `ivy_free(pointer)` | A buffer in the module's memory |
| `ivy_core_create(pointer, length)` | A core from an encoded configuration; `0` if it is not valid |
| `ivy_core_destroy(handle)` | |
| `ivy_core_step(handle, pointer, length, uptimeNanoseconds, unixSeconds)` | Applies an encoded event at that time; returns the encoded effects |
| `ivy_core_public_key(handle)` | 32 bytes |
| `ivy_core_connected_peers`, `ivy_core_connected_peer_endpoints`, `ivy_core_known_peer_endpoints`, `ivy_core_providers` | The core's read-only views |
| `ivy_write_high_water_mark()` | `IvyCore.writeHighWaterMark` |

A function that returns bytes returns a block to free with `ivy_free`: a
little-endian `u32` length, then the bytes. `0` means an unknown handle or
input that does not decode.

The module is a WASI reactor. Of WASI it uses only randomness and standard
error; `core.ts` supplies those and refuses the rest, the clock included: the
time is an argument of every step.
