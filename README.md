# Ivy

Authenticated, bounded peer transport and routing for Swift.

Ivy proves which peer sent an accepted record and bounds the work needed to
receive it. The caller decides what the record means.

Ivy does not validate CIDs, traverse DAGs, store content, authorize processes,
run consensus, or implement settlement.

Ivy is a deterministic core inside an I/O shell. `IvyCore` is the whole
protocol as one value: bytes, time and requests go in as events, and everything
it wants done comes out as effects. `Ivy` is the shell an application uses:
it owns the sockets and the timer and keeps the API below.

## Start

```swift
import Crypto
import Ivy

let ivy = Ivy(config: IvyConfig(
    signingKey: Curve25519.Signing.PrivateKey(),
    listenPort: 4001,
    bootstrapPeers: bootstrapPeers
))

try await ivy.start()
// ...
await ivy.stop()
```

A socket remains private until its signed session handshake completes.
`start()` and `stop()` are ordered and restart-safe.
Sessions authenticate and replay-protect cleartext records; Ivy does not provide
encryption or forward secrecy.

`IvyMode.overlay` uses authenticated Kademlia discovery. `.privateNetwork`
accepts authenticated direct peers but disables discovery, routing, providers,
relay, and broadcast; applications use directed messages for their own private
protocol. Volume exchange is also disabled unless
`privateContentExchangeEnabled` is explicitly set. A private source should use
`authorizesVolumeRequest` when only some authenticated peers may read it.
`.pinned(peer:)` accepts one endpoint identity and disables public discovery.
Configured carriers govern outbound relay initiation; inbound offers grant
transport only and never turn a carrier into an endpoint peer.

## Network roles

Ivy supplies a few small primitives that applications compose:

- `broadcastMessage` announces gossip to the currently connected peers.
- `sendMessage` carries directed sync requests and responses.
- `fetchVolume` retrieves one complete bounded Volume from one provider.
- `fetchVolumeBundle` retrieves, with one request, the Volumes a named peer bundles under a root.

The caller defines gossip IDs, deduplication, forwarding, sync order, and CID
validation. Ivy authenticates the sender, bounds each operation, and keeps these
application protocols independent.

## Volumes

Register a source:

```swift
public protocol IvyContentSource: Sendable {
    func volume(
        rootCID: String,
        maxDataBytes: Int
    ) async -> [ContentEntry]
}

await ivy.setContentSource(store)
```

Return every entry of the complete Volume rooted at `rootCID`, the root's own
included, or return `[]`. Wire identifiers are non-empty ASCII strings, which
keeps equality byte-exact; Ivy does not parse their meaning.

Fetch it:

```swift
let response = await ivy.fetchVolume(rootCID: rootCID)
```

Ivy streams one Volume across ordered frames (4 MiB each by default), up to
64 MiB and 65,535 entries, and returns only after the whole archive is present,
or `.empty`; it never follows links or returns a partial Volume. `servedBy`
identifies the authenticated remote endpoint and is `nil` for a local result.
This does not make Ivy a DAG layer: the caller validates every identifier and
byte before storage.

Provider records are expiring routing hints, not proof of possession, validity,
pinning, or authority. A record is what a peer announced for itself or what a
lookup answer referred; a peer that served content is not recorded as a provider.

## Application messages

```swift
let result = await ivy.sendMessage(
    to: peer,
    topic: "sync",
    payload: encodedMessage
)
```

Ivy delivers incoming messages through `IvyDelegate` with an authenticated
sender. `.enqueued` means local queue acceptance, not remote delivery.

Each authenticated peer is an independent availability zone. Unavailable or
caller-reported deficient content changes provider selection for that root; it
does not disconnect the peer or prevent messages and other roots from using the
same session. Tally only weights peers waiting for a serving slot under load; it
never refuses a peer or the node's own requests.

## Driving the core yourself

A host with its own event loop, or a simulator, can skip the shell:

```swift
import IvyCore

var core = IvyCore(config: config)
for effect in core.step(.start, now: now) { perform(effect) }
// Feed it what happens: .connectionOpened, .received, .writable, .closed,
// .tick at or after the last .wakeAt, .request, .delivered, .jobFinished.
```

The core does no I/O and reads no clock, so the same events at the same times
give the same effects. `IvySimulation` runs many cores over a simulated network
on virtual time and replays a seeded run exactly:

```swift
import IvySimulation

let sim = Simulation(seed: 7)
let a = sim.addNode { IvyConfig(signingKey: $0, stunServers: []) }
let b = sim.addNode { IvyConfig(signingKey: $0, stunServers: []) }
sim.start(a); sim.start(b)
_ = sim.await(.connect(b.endpoint), on: a)
sim.run(for: .seconds(30))
print(sim.traceDigest)
```

## In a browser

`IvyCore` and `IvySimulation` build for WebAssembly, and behave there exactly
as they do natively: `Wasm/run.sh` runs the core's test suite as Wasm and
checks that a seeded network prints the same trace digest in both builds. The
shell does not build for Wasm, because SwiftNIO does not.

```sh
IVY_CORE_ONLY=1 swift build --swift-sdk swift-6.4.0-RELEASE_wasm
```

`IVY_CORE_ONLY=1` leaves the shell and SwiftNIO out of the package, and adds
`IvyWasm`: the core behind a small C ABI. The core needs only
`FoundationEssentials`, which keeps the binary small; full Foundation would
add tens of megabytes of Unicode data.

[`Web/`](Web/README.md) is the shell for JavaScript, in a browser or Node: a
TypeScript package that loads that module and drives it, with the same
methods as the `Ivy` actor. Events and effects cross between the two as
bytes, in the format of [docs/event-codec.md](docs/event-codec.md).

```sh
IVY_WASM_SDK=swift-6.4.0-RELEASE_wasm Web/build.sh
cd Web && npm test
```

It takes its connections as `Transport`s: a WebSocket to a node listening as
below, or an in-memory pair. It keeps the Volumes it serves in IndexedDB,
within a budget.

A browser cannot open a TCP connection either. `IvyWebSocket` lets a node
accept its peers over WebSocket, and dial other nodes the same way:

```swift
import IvyWebSocket

let webSocket = WebSocketTransport(ivy: ivy)
try await webSocket.listen(port: 8080)          // ws://<host>:8080/ivy

try await webSocket.connect(to: peer, host: peer.host, port: 8080)
// ...
await webSocket.stopListening()
```

A WebSocket carries the same sessions as TCP: Ivy uses it as a byte stream and
frames its own records inside binary messages. There is no TLS in the
transport, so terminate `wss` in a proxy in front of it; then pass
`trustForwardedFor: true` to `listen`, and only then, so peers are admitted by
their own address and not the proxy's.

Two browsers cannot accept a connection from each other at all, so they meet
through a node both are connected to, one that has `relayEnabled`. `Web/`'s
`RtcConnector` then signals a WebRTC data channel over that relayed session
and hands it to the core, whose handshake runs over it; the direct session
replaces the relayed one and the node carries nothing more for the pair. See
[Web/README.md](Web/README.md#browser-to-browser).

## Boundary

| Ivy owns | The caller owns |
| --- | --- |
| Session authentication and replay protection | Process authorization and protocol meaning |
| Connection, frame, request, route, and lookup limits | Application batching and policy |
| Endpoint routing and configured carriers | Service or chain topology |
| Opaque Volume transfer | CID validation, DAG interpretation, and storage |
| Signed sender attribution | Consensus, retention, fees, and settlement |

## Documentation

- [Architecture](docs/architecture.md)
- [Correctness invariants](docs/correctness-invariants.md)
- [Moving from 15.x](docs/migration.md)
- [Event codec](docs/event-codec.md)
- [Ivy in JavaScript](Web/README.md)

## Requirements

- Swift 6
- macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, visionOS 1+, or Linux
- One Ed25519 signing key per process identity

```sh
swift build
swift test
```
