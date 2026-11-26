# Ivy

Ivy is Lattice's peer-to-peer networking library for Swift: authenticated,
bounded peer transport and routing.

Ivy proves which peer sent an accepted record and bounds the work needed to
receive it. The caller decides what the record means. Ivy does not validate
CIDs, traverse DAGs, store content, authorize processes, run consensus, or
implement settlement.

| Ivy owns | The caller owns |
| --- | --- |
| Session authentication and replay protection | Process authorization and protocol meaning |
| Connection, frame, request, route, and lookup limits | Application batching and policy |
| Endpoint routing and configured carriers | Service or chain topology |
| Opaque Volume transfer | CID validation, DAG interpretation, and storage |
| Signed sender attribution | Consensus, retention, fees, and settlement |

Sessions authenticate and replay-protect cleartext records. Ivy does not
provide encryption or forward secrecy.

## Requirements

- Swift 6
- macOS 14+, iOS 17+, tvOS 17+, watchOS 10+, visionOS 1+, or Linux
- One Ed25519 signing key per process identity

```sh
swift build
swift test
```

## Quickstart

### 1. Start a node

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

### 2. Send and receive messages

```swift
let result = await ivy.sendMessage(
    to: peer,
    topic: "sync",
    payload: encodedMessage
)
```

Ivy delivers incoming messages through `IvyDelegate` with an authenticated
sender. `.enqueued` means local queue acceptance, not remote delivery.

### 3. Serve Volumes

A *Volume* is a root identifier and the complete set of entries served with
it. The term is defined by
[cashew](https://lattice.build/docs/protocol/cashew/); to Ivy a Volume's
identifiers and bytes are opaque.

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
included, or return `[]`. Identifiers are non-empty ASCII strings, which
keeps equality byte-exact; Ivy does not parse their meaning.

`IvyContentSource` is Ivy's own protocol. It is not cashew's `ContentSource`,
nor the `ContentSource` interface of the [JavaScript package](Web/README.md),
which mirrors it in TypeScript.

### 4. Fetch a Volume

```swift
let response = await ivy.fetchVolume(rootCID: rootCID)
```

- Ivy returns only after the whole Volume is present, or `.empty`. It never
  follows links or returns a partial Volume.
- `servedBy` identifies the authenticated remote endpoint and is `nil` for a
  local result.
- The caller validates every identifier and byte before storage.

The size limits are in
[Volume limits](docs/wire-protocol.md#volume-limits), and the order a fetch
looks in is in
[Where a fetch looks](docs/wire-protocol.md#where-a-fetch-looks).

## What Ivy gives an application

Ivy supplies a few small primitives that applications compose into gossip,
sync and retrieval:

| Call | Does |
| --- | --- |
| `broadcastMessage` | Announces gossip to the currently connected peers |
| `sendMessage` | Carries directed sync requests and responses |
| `fetchVolume` | Retrieves one complete bounded Volume from one provider, or only from the sessions named (`from:`), asked one at a time |
| `fetchVolumeBundle` | Retrieves, with one request, the Volumes a named peer bundles under a root |

The caller defines gossip IDs, deduplication, forwarding, sync order, and CID
validation. Ivy authenticates the sender, bounds each operation, and keeps
these application protocols independent.

### A peer is not condemned for its content

Each authenticated peer is an independent availability zone. Unavailable or
caller-reported deficient content changes provider selection for that root.
It does not disconnect the peer or prevent messages and other roots from
using the same session.

Ivy reads Tally only to weight peers waiting for a serving slot under load.
It never refuses a peer, or the node's own requests, by it. Ivy also records
traffic and protocol violations in Tally.

## Modes

`IvyConfig.mode` chooses who a node talks to and which services it runs.

| Mode | Accepts | Services |
| --- | --- | --- |
| `.overlay` (default) | Any peer | Authenticated Kademlia discovery, provider records, Volume exchange, relay, broadcast |
| `.privateNetwork` | Authenticated direct peers | Directed messages only: no discovery, routing, providers, relay or broadcast. Volume exchange only when `privateContentExchangeEnabled` is set |
| `.pinned(peer:)` | One endpoint identity | No public discovery |

On a private network, applications use directed messages for their own
private protocol. A private source should use `authorizesVolumeRequest` when
only some authenticated peers may read it.

### Relay

A node that cannot dial a peer asks for a route through a third peer:

- from its configured `carriers` first;
- then from connected peers the application marked with
  `ivy.setRelaying(peer, true)`, at most four for one connect.

Peers do not announce in the handshake that they relay, so an application
says it in a message of its own and tells its node. Only mark a peer that
said so: one that does not relay ends the session of a peer that asks.

An inbound route offer grants transport only and never turns a carrier into
an endpoint peer. The rules are in [Relay](docs/wire-protocol.md#relay).

## Documentation

Published at [lattice.build/docs](https://lattice.build/docs/protocol/ivy/).

| Page | Read it to |
| --- | --- |
| [Wire protocol](docs/wire-protocol.md) | Look up what peers send: transports, handshake, records, message tags, bounds, routing, relay, signalling |
| [Architecture](docs/architecture.md) | Understand how Ivy is built, drive `IvyCore` from your own event loop or a simulation, supply a stream, punch through NATs |
| [Correctness invariants](docs/correctness-invariants.md) | Review the laws Ivy must keep, by ID |
| [Ivy in JavaScript](Web/README.md) | Run Ivy in a browser or Node, serve browsers from a node over WebSocket, connect two browsers over WebRTC |
| [Host event codec](docs/event-codec.md) | Write a host that drives the WebAssembly core |
| [Upgrading from 15.x](docs/migration.md) | Move an application from Ivy 15.x |
