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

`websocket.ts` is a `Transport` over the platform's WebSocket, and
`storage.ts` a `ContentSource` in IndexedDB or in memory. `datachannel.ts` is one
over a WebRTC data channel, and `rtc.ts` moves two pages that met through a
node onto one.

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

The tests that reach a native node over a real WebSocket are skipped unless
`IVY_TEST_NODE` names one, which `Wasm/run.sh` sets:

```sh
swift build --product IvyWebSocketTestNode
cd Web && IVY_TEST_NODE=$(swift build --show-bin-path)/IvyWebSocketTestNode npm test
```

## The demo page

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh
cd Web && npm run serve
```

Open `http://localhost:8000/demo/` (`PORT` changes the port). The page starts
two nodes, joins them with an in-memory stream, exchanges messages, fetches a
20 MiB Volume through a stream that fills at 256 KiB, and writes `PASS`, or
`FAIL` and the reason, at the top.

A second page connects to a node outside the browser over WebSocket, fetches
a Volume from it, keeps it in IndexedDB and reads it back:

```sh
swift run IvyWebSocketTestNode $(printf '2a%.0s' $(seq 32))   # prints its key and port
```

```text
http://localhost:8000/demo/node.html?node=ws://127.0.0.1:<port>/ivy&key=<publicKey>&volume=large
```

That node serves `large` (12 MiB) and `small`, and stops when its standard
input closes.

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

## Browser to browser

Two browsers cannot accept a connection from each other. They meet through a
node both are connected to, a carrier with `relayEnabled`, and `RtcConnector`
(`src/rtc.ts`) moves them from there to a WebRTC data channel of their own.

```ts
import { Ivy, RtcConnector } from './dist/src/index.js';

const ivy = new Ivy(module, { signingKey: seed, carriers: [node] }, { dial });
const rtc = new RtcConnector(ivy, {
  // iceServers: [{ urls: 'stun:stun.example.org' }],  // the carrier by default
});
ivy.delegate = rtc.delegate(application);           // before ivy.start()
await ivy.start();

await ivy.connectViaRelay(peer);    // a session through the carrier
// ... which the connector upgrades when it appears. With autoUpgrade off:
const direct = await rtc.upgrade(session);   // the session peerConnected gave

rtc.close();
```

`rtc.delegate(inner)` stands between Ivy and the application's delegate: it
takes the messages on the topic `ivy.rtc/1`, which is the signalling, and
passes everything else through. When the channel opens, the connector hands it
to `connect` at one end and `accept` at the other, the core's handshake runs
over it, and the direct session replaces the relayed one: the application
hears `peerConnected` again, with a `direct` route.

| Option | Default | |
| --- | --- | --- |
| `PeerConnection` | `RTCPeerConnection` | The constructor, for a test to replace |
| `iceServers` | the carrier | STUN servers, where each peer learns the address the other can reach it at. By default that is the carrier the relayed session runs through, asked over UDP at the host and port its WebSocket was reached at (`ivy.reachedAt`), so no third party is involved. `[]` asks no one, and then only peers that can reach each other's own addresses connect. TURN is not used: the carrier already relays |
| `autoUpgrade` | `true` | Try whenever a relayed session to an endpoint appears |
| `deadline` | `20000` | Milliseconds an attempt may take |

`upgrade` resolves `true` when the peer's session is direct and `false` when
it is not, and then the relayed session is as it was. Either end may call
it, and both may at once: the peer with the smaller public key makes the
offer, so there is one connection. An attempt already running is joined.

- Signalling is taken only from the relayed session that is the peer's now,
  and only when that peer is an endpoint. From a direct session or a carrier
  it is dropped, and nothing malformed ends a session: at most it ends the
  attempt.
- One attempt per peer at a time, three for one relayed session, 20 seconds
  each. A failed attempt closes its peer connection.
- The relayed session is signed end to end, so the carrier cannot forge
  signalling, only drop it. The channel is authenticated by the core's own
  handshake over it, whoever carried the signalling.
- Neither application hears a disconnect: each hears `peerConnected` for the
  direct session. The other end closes the relayed session as it finishes,
  and word of that through the carrier can overtake the handshake's last
  record on the channel; the core holds that disconnect until it knows
  whether the handshake completed.

`DataChannelTransport` (`src/datachannel.ts`) is the `Transport` over the
channel, and can be used by itself over any ordered, reliable
`RTCDataChannel`, with both ends using it. A data channel cannot be paused, so
it carries a credit window: each end sends at most 1 MiB that its peer has
not granted back, in messages of at most 16 KiB, and a receiver holds at most
that much unread and closes a peer that sends more. Give it the host its peer
was observed at; the connector reads the remote address of the selected ICE
candidate pair and, where the browser hides it, uses
`<peer key>.webrtc.invalid`.

The message formats and the reasoning are in
[docs/architecture.md](../docs/architecture.md#browser-to-browser).

`demo/rtc.html` runs all of it in one page with the browser's own
`RTCPeerConnection`: a carrier and two peers, a relayed session, the upgrade,
and a 20 MiB Volume over the data channel.

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh
cd Web && npm run serve
```

Open `http://localhost:8000/demo/rtc.html`. It writes `PASS`, or `FAIL` and
the reason, at the top.

`demo/peers.html` does it between two pages and a real node: one page serves
a Volume from IndexedDB, the other meets it through the node, moves to a data
channel between the two pages and fetches the Volume over it. The node must
carry sessions between its peers; the test node does with `--relay`:

```sh
swift build
.build/debug/IvyWebSocketTestNode <64 hex digits> --relay
```

It prints its public key and port. Keep its standard input open, then open

```
http://localhost:8000/demo/peers.html?node=ws://127.0.0.1:<port>/ivy&key=<publicKey>&role=serve
```

That page shows the address to open in a second tab, which writes `PASS`.

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
delegate, an exhausted byte budget. A transport that cannot stop its peer
buffers what arrives in between.

`memoryPair` (`src/memory.ts`) is a complete example.

## WebSocket

```ts
import { connectWebSocket, webSocketDialer } from './dist/src/index.js';

// A stream this page opened, to a node listening with `WebSocketTransport`.
await ivy.connect(endpoint, await connectWebSocket('wss://node.example/ivy'));

// Or let the core dial: bootstrap peers, carriers, providers it discovers.
new Ivy(module, config, {
  dial: webSocketDialer((endpoint) => `ws://${endpoint.host}:${endpoint.port}/ivy`),
});
```

`new WebSocketTransport(socket)` wraps a socket that is already open. It works
the same in a browser and in Node, on the `WebSocket` both have.

- It sends binary messages of at most 64 KiB and delivers at most 64 KiB a
  read. A text message closes it, as at a node.
- It stops reporting itself writable at 64 KiB of `bufferedAmount` and says
  it has drained at 32 KiB. A WebSocket has no event for that, so the count
  is looked at every turn of the event loop for 50 ms and on a 10 ms timer
  after that. A browser slows timers to one a second in a tab that is not
  showing, so a socket that stays full longer than those 50 ms sends about
  one burst a second there.
- **What arrives cannot be slowed, only dropped.** A WebSocket in a page
  cannot be paused and TCP flow control does not reach `onmessage`: the core
  stops asking for bytes on a connection it is holding back, but the browser
  keeps receiving, and the transport queues it. A peer that sends only what
  it was asked for fills that queue with no more than those answers; one
  that keeps sending is closed when 128 MiB waits unread.
- `observedHost` is the host in the URL. A browser does not say which
  address a name resolved to, so a name is admitted as a netgroup of its own
  (`raw:<name>` in the core), and an IP literal by its prefix as usual.

## Storage

```ts
import { IndexedDBContentSource } from './dist/src/index.js';

const store = await IndexedDBContentSource.open('volumes', { budget: 512 * 1024 * 1024 });
await store.put(rootCID, entries);        // also has, delete, roots, putBundle
ivy.setContentSource(store);
```

`MemoryContentSource` is the same store in memory, for Node and for tests. Both
hold whole Volumes by root. Each counts as the archive it is sent as, which
is also what `maxDataBytes` bounds: a Volume over it is answered `[]`. When a
`put` would pass the budget, the Volumes served longest ago are dropped
first, and one that alone is over it is refused. A bundle is kept with the
Volume it is under and goes with it. `authorizes` in the options decides who
may read; left out, anyone may.

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
