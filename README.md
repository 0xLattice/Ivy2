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
protocol. Exact-CID content exchange is also disabled unless
`privateContentExchangeEnabled` is explicitly set. A private source should use
`authorizesContentRequest` when only some authenticated peers may read it.
`.pinned(peer:)` accepts one endpoint identity and disables public discovery.
Configured carriers govern outbound relay initiation; inbound offers grant
transport only and never turn a carrier into an endpoint peer.

## Network roles

Ivy supplies three small primitives that applications compose:

- `broadcastMessage` announces gossip to the currently connected peers.
- `sendMessage` carries directed sync requests and responses.
- `fetchContent` retrieves one exact content selection from available providers.
- `fetchVolume` retrieves one complete bounded Volume from one provider.
- `fetchVolumeBundle` retrieves, with one request, the Volumes a named peer bundles under a root.

The caller defines gossip IDs, deduplication, forwarding, sync order, and CID
validation. Ivy authenticates the sender, bounds each operation, and keeps these
application protocols independent.

## Exact content

Register a source:

```swift
public protocol IvyContentSource: Sendable {
    func content(
        rootCID: String,
        cids: [String],
        maxDataBytes: Int
    ) async -> [ContentEntry]
}

await ivy.setContentSource(store)
```

`cids` is the complete canonical selection and includes `rootCID`. Return every
entry exactly once within `maxDataBytes`, or return `[]`. Wire identifiers are
non-empty ASCII strings, which keeps equality byte-exact; Ivy does not parse
their meaning.

Fetch the same explicit selection:

```swift
let response = await ivy.fetchContent(
    rootCID: rootCID,
    cids: selectedCIDs
)
```

Ivy returns the whole selection or `.empty`; it never follows links or returns a
partial success. `servedBy` identifies the authenticated remote endpoint and is
`nil` for a local result. The caller validates identifiers and bytes before
storage.

Selections must fit one frame body — 4 MiB by default, or the larger size a
connection negotiates when both peers raise their local `protocolMaxFrameSize`.
Larger application objects must be split by caller-defined boundaries.

`fetchVolume(rootCID:)` is the complete-boundary counterpart. Ivy streams one
Volume across ordered frames (4 MiB each by default), up to 64 MiB and 65,535 entries, and returns
only after the whole archive is present. This does not make Ivy a DAG layer:
the caller still validates every identifier and byte before storage.

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

## Boundary

| Ivy owns | The caller owns |
| --- | --- |
| Session authentication and replay protection | Process authorization and protocol meaning |
| Connection, frame, request, route, and lookup limits | Application batching and policy |
| Endpoint routing and configured carriers | Service or chain topology |
| Exact opaque content transfer | CID validation, DAG interpretation, and storage |
| Signed sender attribution | Consensus, retention, fees, and settlement |

## Documentation

- [Architecture](docs/architecture.md)
- [Correctness invariants](docs/correctness-invariants.md)
- [Moving from 15.x](docs/migration.md)

## Requirements

- Swift 6
- macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, visionOS 1+, or Linux
- One Ed25519 signing key per process identity

```sh
swift build
swift test
```
