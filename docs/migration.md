# Moving from Ivy 15.x

Ivy 2.0 is the same protocol with a different inside, less content selection
(below). Nothing else on the wire changed: the session version is still 9,
every remaining message keeps its tag and encoding, and a 2.0 node and a
15.0.1 node interoperate. The frozen vectors in
`MessageTests` and `SessionProtocolTests` are carried over byte for byte, and
`Interop/run.sh` builds one program against each version and runs them against
each other over TCP in both directions: handshake, messages, a multi-frame
Volume, a bundle and a lookup.

## For an application using `Ivy`

Replace the dependency. Every method and delegate callback of the `Ivy` actor
keeps its name, signature and meaning, except the content selection ones
removed below.

Added:

- `boundPort`, the port actually bound when `listenPort` is 0.
- `diagnostics`, the core's counters.
- Two more library products, `IvyCore` and `IvySimulation`.

Removed: content selection. Volumes are the one way to fetch.

- `Ivy.fetchContent` and `IvyContentSource.content` /
  `authorizesContentRequest` are gone. Use `fetchVolume` and `volume` /
  `authorizesVolumeRequest`. A `content` method left on a conformer is harmless.
- Message tags 26 (`contentRequest`) and 50 (`contentResponse`) are retired
  and will not be reused. `contentUnavailable` (58) stays: it refuses Volume
  and bundle requests.

Also removed: the `DEBUG`/`IVY_TESTING` hooks (`…ForTesting`) that forced an
interleaving; a test now states the interleaving as a sequence of events. One
hook stays, `setDialEndpointRewriteForTesting`, because lattice-node's tests
use it to run nodes that advertise routable addresses on one machine. It
redirects the shell's dial and the core never sees it.

## Behaviour that differs

These are the places where 2.0 does not do exactly what 15.0.1 did.

| Area | 15.0.1 | 2.0 |
| --- | --- | --- |
| Outbound backpressure | Followed NIO's channel writability (64 KiB high, 32 KiB low water) | The core counts bytes written since the transport last reported `writable` and reports backpressure past 64 KiB. Same threshold; the signal to resume is "everything written has drained" |
| Reading during a delivery | The decoder kept decoding, up to two frames per connection, while the delegate ran | The connection is not read while a record is with the delegate. Less is buffered and the peer is held back the same way; a malformed length behind the held record is noticed when the record is released, not before |
| Relay forwarding wait | `Task.sleep(for:)` raced against writability | A stored deadline. This removes the one use of `Task.sleep(for:)`, which lattice-node bans under Swift 6.3 optimisation |
| Stale completions | Rejected by run and operation generations | Cannot occur: stop clears the state and identifiers are not reused |

One documentation fix: 15.0.1's architecture doc said that exhausting the
inbound byte budget closes the connection. The code paused direct connections
and closed only relayed ones. 2.0 keeps the code's behaviour and the doc now
says so.

## Carried over unchanged, but worth knowing

A node that configures a peer as a carrier accepts only keepalives and relay
control from it. A relay-enabled overlay node sends `findNode` to its routed
peers on its routing refresh (first after 30 s), and an endpoint that
configured it as a carrier treats that as a violation and ends the session.
15.0.1 behaves the same way; 2.0 reproduces it and does not change it here.

## Driving the core directly

`IvyCore.step(event, now)` is public. A host that already runs a deterministic
loop can drop the `Ivy` actor and feed the core itself; see the README. The
contract for whoever plays the shell:

- Report a new connection with `connectionOpened` and do not read it until the
  core emits `resumeReading`. Stop on `pauseReading`.
- Deliver bytes with `received` in order. Hand over one read at a time: issue
  the next read after the step that took the last.
- Send `writable(conn)` whenever everything written to a connection has left
  the send buffer.
- Send `tick` at or after the instant in the latest `wakeAt`.
- Answer every `deliver` and `peerConnected` with `delivered(token)`, and every
  `startJob` with exactly one `jobFinished`, even after `cancelJob`.
- Answer `dial` with `connectionOpened(…, .outbound(dial), …)` or `dialFailed`.

## Not done here

- lattice-node still uses the `Ivy` actor. Putting `IvyCore` into the node's
  simulator is where whole-system simulation pays off, and is a change to the
  node.
- Tally keeps its own clock. The core reaches it through `PeerLedger`, and
  reads only `servingPriority`; a simulation supplies its own ledger.
- Signing and verification run inside the step, as they did on the actor.
- Throughput is measured only by `ThroughputTests`, not against 15.0.1.
