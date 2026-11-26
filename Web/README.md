# Ivy in JavaScript

How to run Ivy in a browser or Node 22+, and how to let browsers reach a
native node. This package is the shell around `IvyCore` for JavaScript: the
core runs as a WebAssembly module and this package drives it. It is the
counterpart of `Sources/Ivy`, and like it decides nothing: events go in,
effects come out.

```text
application: delegate, content source, transports
                    |
shell.ts: connections, one timer, requests as promises
                    |   encoded events in, encoded effects out
core.ts -> ivy.wasm (Sources/IvyWasm, around IvyCore.step)
```

| File | What it is |
| --- | --- |
| `src/shell.ts` | The `Ivy` class |
| `src/websocket.ts` | A `Transport` over the platform's WebSocket |
| `src/datachannel.ts` | A `Transport` over a WebRTC data channel |
| `src/rtc.ts` | Moves two pages that met through a node onto a data channel |
| `src/storage.ts` | A `ContentSource` in IndexedDB or in memory |
| `src/memory.ts` | An in-memory pair of `Transport`s |

A browser cannot open a TCP connection or accept one. It reaches a node over
[WebSocket](#websocket) and another browser over
[WebRTC](#browser-to-browser). What goes on those streams is in the
[wire protocol](../docs/wire-protocol.md#transports).

## Build and test

You need a swift.org toolchain with its matching Wasm SDK (not Xcode's) and
Node 22 or later.

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh   # dist/ivy.wasm and dist/**/*.js
cd Web && npm test
```

Set `SWIFT` to run a particular toolchain, for example
`SWIFT="swiftly run +6.4.1 swift"`. `Wasm/run.sh` does both of the above
after its own checks.

### What the build does

- It builds the package with `IVY_CORE_ONLY=1`, which leaves the native shell
  and SwiftNIO out and adds `IvyWasm`: the core behind a small C ABI.

  ```sh
  IVY_CORE_ONLY=1 swift build --swift-sdk swift-6.4.0-RELEASE_wasm
  ```

- With `wasm-opt` (binaryen) installed the module is stripped and optimised:
  about 9 MiB, 3 MiB compressed, from 29 as built.
- On a Mac the script first edits the copy of swift-crypto's manifest that
  this build fetched, in `.build-wasm`. That manifest gives its targets a
  resource when the machine building is a Mac, whatever it builds for, and
  the code SwiftPM generates to find the resource links all of Foundation and
  its ICU tables: 40 MiB that nothing calls. The script fails if they are in
  the module it made.

### Running the tests

The tests run against the real module; `IVY_WASM` points them at another
build of it.

The tests that reach a native node over a real WebSocket are skipped unless
`IVY_TEST_NODE` names one, which `Wasm/run.sh` sets:

```sh
swift build --product IvyWebSocketTestNode
cd Web && IVY_TEST_NODE=$(swift build --show-bin-path)/IvyWebSocketTestNode npm test
```

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

One module instance holds any number of nodes. `destroy()` frees a node's
core.

It takes its connections as `Transport`s: a WebSocket to a node, a data
channel to another page, or an in-memory pair.

### Differences from the native `Ivy` actor

The methods are the native `Ivy` actor's, with these differences:

| Area | In JavaScript |
| --- | --- |
| Results | Everything the core answers is a promise, `sendMessage` included |
| Cancelling | A request takes an `AbortSignal` where the native one is cancelled with its task. Aborting completes it as the core answers a cancelled request: an empty Volume, `false`, or `connect` rejecting with `IvyError('cancelled')` |
| `fetchVolume` | Takes its session and limits as options |
| Listening and STUN | There is no listener and no STUN. Streams are handed in with `accept` and `connect`, the core's own dials go to the `dial` option, and `reportPublicAddress` tells the core an address learned elsewhere |
| Admission | There is no admission lease: the core admits or closes an accepted stream by its connection and netgroup limits, and events are applied as they are made, so nothing queues ahead of it |
| Tally | Traffic is not recorded in a Tally ledger; peers waiting for a serving slot are served in turn |
| `discoverProviders` | Is the native `discoverProviderAddresses`: each provider's endpoint with the `webAddresses` its record carries |
| `ContentSource` | The TypeScript form of the native `IvyContentSource`. It is not cashew's `ContentSource` |

### Finding providers a page can dial

`discoverProviders` returns each provider's endpoint with its
[web addresses](../docs/wire-protocol.md#web-addresses), the `ws://` or
`wss://` URLs this page can dial:

- `{ url }` where the provider listens;
- `{ url, via }` to connect to peer `via` there and relay through it.

The core tells every session the page's own addresses, none unless
`setWebAddresses` is called, and that is what makes a node answer with them.
A node that does not know web addresses ignores this and answers without; its
providers come back with an empty list.

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

`new WebSocketTransport(socket)` wraps a socket that is already open. It
works the same in a browser and in Node, on the `WebSocket` both have.

### How the page's end behaves

- **Sizes.** It sends binary messages of at most 64 KiB and delivers at most
  64 KiB a read. A text message closes it, as at a node.
- **Writability.** It stops reporting itself writable at 64 KiB of
  `bufferedAmount` and says it has drained at 32 KiB. A WebSocket has no
  event for that, so the count is looked at every turn of the event loop for
  50 ms and on a 10 ms timer after that. A browser slows timers to one a
  second in a tab that is not showing, so a socket that stays full longer
  than those 50 ms sends about one burst a second there.
- **What arrives cannot be slowed, only dropped.** A WebSocket in a page
  cannot be paused and TCP flow control does not reach `onmessage`: the core
  stops asking for bytes on a connection it is holding back, but the browser
  keeps receiving, and the transport queues it. A peer that sends only what
  it was asked for fills that queue with no more than those answers; one
  that keeps sending is closed when 128 MiB waits unread.
- **Observed host.** `observedHost` is the host in the URL. A browser does
  not say which address a name resolved to, so a name is admitted as a
  netgroup of its own (`raw:<name>` in the core), and an IP literal by its
  prefix as usual.

## Accepting browsers on a node

On the native side, `IvyWebSocket` lets a node accept its peers over
WebSocket, and dial other nodes the same way:

```swift
import IvyWebSocket

let webSocket = WebSocketTransport(ivy: ivy)
try await webSocket.listen(port: 8080)          // ws://<host>:8080/ivy

try await webSocket.connect(to: peer, host: peer.host, port: 8080)
// ...
await webSocket.stopListening()
```

A WebSocket carries the same sessions as TCP: Ivy uses it as a byte stream
and frames its own records inside binary messages.

### TLS and proxies

There is no TLS in the transport. Terminate `wss` in front of the listener,
in a reverse proxy or a load balancer.

Behind a proxy every socket comes from the proxy, so pass
`trustForwardedFor: true` to `listen`. It takes the peer's address from the
last hop of `X-Forwarded-For`, the one the proxy itself wrote, and refuses a
request without it.

Enable it **only** behind a proxy that sets the header and that nothing can
bypass: the address decides netgroup admission, and a peer that reaches the
listener directly would choose its own. It is off by default.

### STUN on the same port

The listener also answers STUN Binding requests on the same port over UDP,
so a page learns its own address from the node it is connected to and from
no one else. A page asks before connecting to another page.
`listen(…, stun: false)` leaves it out.

- UDP does not pass through the proxy that terminates `wss`. The page asks at
  the host and port it dialled, so UDP to that port must reach the
  listener's.
- The source of a request is not verified, so an answer can be aimed at
  someone who did not ask. It is 32 bytes for a request of 20 or more (44
  over IPv6), and one node sends at most 20 a second to one address (one
  IPv6 /64) and answers at most 4096 addresses in a second.

### Origin

The listener does not look at `Origin`. Any page may open a socket, as any
peer may open a TCP connection; what it can do is decided by the session
handshake.

### Telling browsers where to connect

A provider record carries its provider's
[web addresses](../docs/wire-protocol.md#web-addresses).

| Call on the native `Ivy` | Does |
| --- | --- |
| `setWebAddresses(_:)` | Sets the node's own addresses |
| `setAutoRelay(true)` | With no declared addresses, [advertises relays](../docs/wire-protocol.md#advertising-relays-automatically) the node can be reached through |
| `discoverProviderAddresses(rootCID:)` | Returns each provider with its addresses |
| `webAddresses(of:)` | Returns what a connected peer advertised |

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
passes everything else through.

When the channel opens, the connector hands it to `connect` at one end and
`accept` at the other, the core's handshake runs over it, and the direct
session replaces the relayed one. The application hears `peerConnected`
again, with a `direct` route, and no disconnect. The node carries nothing
more for the pair.

The signalling format, its limits, and why the channel is authenticated
whoever carried the signalling are in
[Browser to browser: `ivy.rtc/1`](../docs/wire-protocol.md#browser-to-browser-ivyrtc1).

### Options

| Option | Default | Meaning |
| --- | --- | --- |
| `PeerConnection` | `RTCPeerConnection` | The constructor, for a test to replace |
| `iceServers` | the carrier | STUN servers, where each peer learns the address the other can reach it at. By default that is the carrier the relayed session runs through, asked over UDP at the host and port its WebSocket was reached at (`ivy.reachedAt`), so no third party is involved. `[]` asks no one, and then only peers that can reach each other's own addresses connect. TURN is not used: the carrier already relays |
| `autoUpgrade` | `true` | Try whenever a relayed session to an endpoint appears |
| `deadline` | `20000` | Milliseconds an attempt may take |

### `upgrade`

`upgrade` resolves `true` when the peer's session is direct and `false` when
it is not, and then the relayed session is as it was. Either end may call
it, and both may at once: there is one connection. An attempt already
running is joined. A failed attempt closes its peer connection.

The peer connection is also closed when its stream closes, when the peer
disconnects, and when the connector is closed.

### The data channel transport

`DataChannelTransport` (`src/datachannel.ts`) is the `Transport` over the
channel. It can be used by itself over any ordered, reliable
`RTCDataChannel`, with both ends using it.

- It carries a [credit window](../docs/wire-protocol.md#webrtc-data-channel),
  because a data channel cannot be paused.
- A receiver hands bytes over only as the core asks, at most 64 KiB at a
  time.
- A sender regains credit once a round trip at best, so the window is what
  one round trip carries: 1 MiB keeps a 100 ms path above 10 MiB/s.
- The stream is writable while it has credit and the channel's own buffer is
  under 256 KiB.

Give it the host its peer was observed at. The connector reads the remote
address of the selected ICE candidate pair. A browser often hides that
address, behind an mDNS name of its own choosing or behind nothing; a name
says nothing of where a peer is and the peer picks it, so the stream is then
given `<peer key>.webrtc.invalid`, for the key the signalling was
authenticated by. `NetGroup` puts a host that is not an address in a group of
its own, so such peers are admitted and do not share a netgroup: the netgroup
limit does not bound them, and `maxConnections` does.

## Storage

```ts
import { IndexedDBContentSource } from './dist/src/index.js';

const store = await IndexedDBContentSource.open('volumes', { budget: 512 * 1024 * 1024 });
await store.put(rootCID, entries);        // also has, delete, roots, putBundle
ivy.setContentSource(store);
```

`MemoryContentSource` is the same store in memory, for Node and for tests.

- Both hold whole Volumes by root.
- Each counts as the archive it is sent as, which is also what `maxDataBytes`
  bounds: a Volume over it is answered `[]`.
- When a `put` would pass the budget, the Volumes served longest ago are
  dropped first, and one that alone is over it is refused.
- A bundle is kept with the Volume it is under and goes with it.
- `authorizes` in the options decides who may read; left out, anyone may.

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

## Demo pages

Build and serve first:

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh
cd Web && npm run serve
```

Each page writes `PASS`, or `FAIL` and the reason, at the top. `PORT` changes
the port.

### Two nodes in one page

Open `http://localhost:8000/demo/`. The page starts two nodes, joins them
with an in-memory stream, exchanges messages, and fetches a 20 MiB Volume
through a stream that fills at 256 KiB.

### A page and a native node

The page connects to a node outside the browser over WebSocket, fetches a
Volume from it, keeps it in IndexedDB and reads it back.

1. Start the node. It prints its key and port, serves `large` (12 MiB) and
   `small`, and stops when its standard input closes.

   ```sh
   swift run IvyWebSocketTestNode $(printf '2a%.0s' $(seq 32))
   ```

2. Open

   ```text
   http://localhost:8000/demo/node.html?node=ws://127.0.0.1:<port>/ivy&key=<publicKey>&volume=large
   ```

### Two peers and a carrier in one page

Open `http://localhost:8000/demo/rtc.html`. It runs a carrier and two peers
in one page with the browser's own `RTCPeerConnection`: a relayed session,
the upgrade, and a 20 MiB Volume over the data channel.

### Two pages and a native node

One page serves a Volume from IndexedDB, the other meets it through the node,
moves to a data channel between the two pages and fetches the Volume over it.

1. Start a node that carries sessions between its peers. The test node does
   with `--relay`. It prints its public key and port; keep its standard input
   open.

   ```sh
   swift build
   .build/debug/IvyWebSocketTestNode <64 hex digits> --relay
   ```

2. Open

   ```text
   http://localhost:8000/demo/peers.html?node=ws://127.0.0.1:<port>/ivy&key=<publicKey>&role=serve
   ```

3. That page shows the address to open in a second tab, which writes `PASS`.

## The module's interface

`Sources/IvyWasm/main.swift` exports a small C ABI; `src/core.ts` is its only
caller. Events, effects and the configuration cross it as the
[host event codec](../docs/event-codec.md) encodes them, and
`test/vectors.json` pins that encoding for both sides.

| Export | Does |
| --- | --- |
| `ivy_alloc(length)`, `ivy_free(pointer)` | A buffer in the module's memory |
| `ivy_core_create(pointer, length)` | A core from an encoded configuration; `0` if it is not valid |
| `ivy_core_destroy(handle)` | Frees a core |
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
