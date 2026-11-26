# Upgrading from Ivy 15.x

What an application on Ivy 15.x changes to run on Ivy 2. The protocol is the
same: the session version is still 9, every remaining message keeps its tag
and encoding, and a node on Ivy 2 and a node on 15.0.1 interoperate.
`Interop/run.sh` builds one program against each version and runs them
against each other over TCP in both directions: handshake, messages, a
multi-frame Volume, a bundle and a lookup.

## Steps

1. Replace the dependency.
2. Replace content selection calls with Volume calls (below).
3. Remove any use of the `…ForTesting` hooks (below).
4. Read [Behaviour that differs](#behaviour-that-differs) for anything your
   application relied on.

Every other method and delegate callback of the `Ivy` actor keeps its name,
signature and meaning. `config`, `tally` and `localID` are isolated to the
actor, so code that reads them with `await` builds unchanged.

## Removed

### Content selection

Volumes are the one way to fetch.

| Removed | Use |
| --- | --- |
| `Ivy.fetchContent` | `fetchVolume` |
| `IvyContentSource.content` | `volume` |
| `IvyContentSource.authorizesContentRequest` | `authorizesVolumeRequest` |

A `content` method left on a conformer is harmless.

Message tags 26 (`contentRequest`) and 50 (`contentResponse`) are retired.
`contentUnavailable` (58) stays: it refuses Volume and bundle requests.

### Test hooks

The `DEBUG`/`IVY_TESTING` hooks (`…ForTesting`) that forced an interleaving
are gone. State the interleaving as a sequence of events to `IvyCore`
instead. `setDialEndpointRewriteForTesting` stays.

## Added

- `TransportConnection`, `reserveInboundAdmission`, `accept(_:admission:)`,
  `connect(to:over:)` and `IvyError.streamHasNoObservedHost`, for
  [supplying a stream](architecture.md#supplying-a-stream).
- `boundPort`, the port actually bound when `listenPort` is 0.
- `diagnostics`, the core's counters.
- Two more library products, `IvyCore` and `IvySimulation`. A host that runs
  its own loop can drive the core directly: see
  [The contract for a shell](architecture.md#the-contract-for-a-shell).

## Behaviour that differs

| Area | 15.0.1 | Ivy 2 |
| --- | --- | --- |
| Outbound backpressure | Followed NIO's channel writability (64 KiB high, 32 KiB low water) | Backpressure is reported past 64 KiB written since the transport last reported `writable`. Same threshold; the signal to resume is "everything written has drained" |
| Reading during a delivery | The decoder kept decoding, up to two frames per connection, while the delegate ran | The connection is not read while a record is with the delegate. A malformed length behind the held record is noticed when the record is released, not before |
| Other traffic from a configured carrier | A violation: the session ended and did not reconnect | Dropped. The carrier's session stays up for keepalives and relay control |
| Two Volume fetches needing the same unconnected provider | The second found the first's dial in progress and returned empty | The second waits for that dial and is served |
| A Volume request for a link with no room | Answered empty at once, as if no peer held the Volume | Waits for the link, up to `requestTimeout` |
| A keepalive, "not available" or relay control record for a link past its write mark | Dropped whenever the socket was not writable | Written from a reserve of one more mark, so it is dropped only when the transport has stopped draining |
| A second session with a peer that already has one | The session with the smaller ID was kept, whatever each ran over | A direct session is kept over a relayed one; between two of a kind, the smaller ID |
## Mixed networks

A peer on 15.x keeps the smaller session ID whatever the route. When two
peers that met through a carrier move to a direct session, an Ivy 2 end and a
15.x end can therefore disagree and drop the session. Only move to a direct
session (`connect(to:over:)`, `PunchConnector`) toward a peer on Ivy 2.

The other notes on older peers are in
[Upgrading and older peers](wire-protocol.md#upgrading-and-older-peers).
