# Ivy architecture

How Ivy is built: a deterministic core that makes every decision, inside a
shell that does the I/O. Read this to work on Ivy, to drive the core from
your own event loop, or to supply a new kind of connection.

What peers send each other is in the [wire protocol](wire-protocol.md).

```text
caller: authority, validation, storage, protocol meaning
                         |
Ivy (shell): sockets, one timer, delegate and storage calls
                         |   events in, effects out
IvyCore: admission, sessions, routing, content, relay
```

Ivy turns an untrusted byte stream into bounded records attributed to peer
keys. Authentication proves key control, not application authority.

## Targets

| Target | What it is |
| --- | --- |
| `IvyCore` | The whole protocol as one value. No I/O, no clock. Builds for WebAssembly |
| `Ivy` | The shell an application uses: TCP, the timer, STUN, the delegate and content source |
| `IvyWebSocket` | Streams over WebSocket, for peers that cannot open TCP. A separate product, so a node that does not want it does not build it |
| `IvySimulation` | Many cores over a simulated network on virtual time |
| `IvyWasm` | The core behind a small C ABI, for the [JavaScript shell](../Web/README.md) |

## The core

Every decision Ivy makes is made by `IvyCore`, a value with one entry point:

```swift
mutating func step(_ event: Event, now: Timestamp) -> [Effect]
```

**Events** are everything that can happen to Ivy: a connection opened, bytes
arrived, a connection can be written again, time passed (`tick`), the
application asked for something, a storage job finished.

**Effects** are everything Ivy wants done: dial, write, close, stop or resume
reading a connection, deliver a message, start or cancel a storage job,
answer a request, and `wakeAt`, the earliest deadline it holds.

The core never waits, reads a clock, opens a socket, starts a task or draws
randomness it was not given. The same events at the same times always give
the same effects. `IvyCoreTests` asserts this on a multi-node run, and the
same seed gives the same trace in separate processes.

### What the core holds as state

Nothing in the core is a suspended task. Each thing that takes time is a
value it can inspect:

| Concern | How the core holds it |
| --- | --- |
| Timers | One deadline table. `tick` expires what has passed, and each step emits one `wakeAt` |
| Delivery to the application | `deliver(token, …)`. The connection's next record is held, and the connection not read, until `delivered(token)` |
| Inbound byte budget | Counters charged as bytes join a frame and released when its record has been handled. Exhaustion emits `pauseReading`, release emits `resumeReading` |
| Outbound backpressure | The core counts what it wrote since the last `writable(conn)` and holds chunk cursors, relay forwards, Volume requests and application waiters past 64 KiB |
| A lookup | A stored query: candidates, who was asked, the round, what is outstanding |
| A served request | A serving state with an explicit phase. A granted slot advances it in the same step |
| A relay forward waiting for room | A stored deadline |

Keepalives, "not available", handshake and relay control records are still
written past the 64 KiB mark, from a reserve of 64 KiB more, so a peer
waiting on one is not left to time out while a Volume is in flight. Such a
record is dropped only when the transport has stopped draining.

### Injected dependencies

Signatures, traffic evidence and randomness are injected:

| Protocol or type | Production | Simulation |
| --- | --- | --- |
| `IvySignatureScheme` | Ed25519 | A repeatable stand-in |
| `PeerLedger` | Tally | A ledger of its own |
| `CoreRandom` | The system generator | A seeded generator |

`IvySimulation` needs stand-ins because a session ID covers both handshake
signatures and decides which of two simultaneous sessions survives.

Signing and verification run inside the step. The core records traffic and
protocol violations into the ledger and reads only `servingPriority`, when
content requests contend for serving slots. Every Volume chunk served is
reported through `recordServed`, which debits the peer's standing by its
archive bytes. Tally keeps its own clock.

## The shell

The shell (`Ivy`, `StreamShell`, `STUNClient`) owns everything the core does
not: connections, the single timer, STUN, calls into `IvyDelegate` and
`IvyContentSource`, and the map from request to waiting caller. It decides
nothing.

### The contract for a shell

`IvyCore.step` is public. A host with its own event loop, or a simulator,
can drop the `Ivy` actor and feed the core itself:

```swift
import IvyCore

var core = IvyCore(config: config)
for effect in core.step(.start, now: now) { perform(effect) }
```

Whoever plays the shell must:

1. Report a new connection with `connectionOpened` and not read it until the
   core emits `resumeReading`. Stop on `pauseReading`.
2. Deliver bytes with `received` in order, one read at a time: issue the next
   read after the step that took the last.
3. Send `writable(conn)` whenever everything written to a connection has left
   the send buffer.
4. Send `tick` at or after the instant in the latest `wakeAt`.
5. Answer every `deliver` and `peerConnected` with `delivered(token)`, and
   every `startJob` with exactly one `jobFinished`, even after `cancelJob`.
6. Answer `dial` with `connectionOpened(…, .outbound(dial), …)` or
   `dialFailed`.
7. Report the connection's end with `closed`.

A host that cannot hold Swift values passes events and effects as bytes: see
the [host event codec](event-codec.md).

### Simulation

`IvySimulation` runs many cores over a simulated network on virtual time and
replays a seeded run exactly:

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

## Connections

### Supplying a stream

A connection is a `TransportConnection`: an ordered, reliable byte stream
that delivers bytes only when asked, says whether it has room for more, and
reports its close once. Framing, byte budgets, admission, the handshake and
sessions are all above it and the same for every stream. TCP is one supplier
(`TCPStream`) and takes the same path as any other.

Whoever establishes a stream hands it to Ivy:

| Direction | Calls | Notes |
| --- | --- | --- |
| Inbound | `reserveInboundAdmission(observedHost:)`, then `accept(_:admission:)` | The lease is taken before anything is spent on the peer, admits one stream of the netgroup it was reserved for, and belongs to the run that issued it |
| Outbound | `connect(to:over:)` | The stream is closed unless it becomes the peer's session. There is no falling back to another route or a carrier |

A stream must report the host its peer was observed at: netgroup admission
keys on it. Its address is not one Ivy can dial, so it is kept out of routing
unless the peer advertises a listen address of its own.

### Admission

Inbound capacity is reserved by global and netgroup limits before a
connection is read: the shell reports a new connection unread, and the core
answers with `resumeReading` or `close`. Rejected sockets cannot buffer
protocol input. The limits are in
[Bounds](wire-protocol.md#connections-and-work).

A socket that has not completed the [handshake](wire-protocol.md#handshake)
is pending: absent from routing, delegates, content and application messages.

### WebSocket

`WebSocketTransport` listens and dials for one `Ivy`, and hands each upgraded
connection over by the two calls above. What goes on the socket is in
[Transports](wire-protocol.md#websocket); running the listener for browsers
is in [Ivy in JavaScript](../Web/README.md#accepting-browsers-on-a-node).

How the listener bounds a peer:

- **Reads are pulled, as on TCP.** The socket is not read unless the core
  asked for bytes, so a connection held back leaves its data in the kernel.
  Control frames are behind that data, so a ping is answered when the
  connection is next read, not while it is held. Only the latest ping is
  answered if the peer is not reading its answers.
- **Outbound, a record is split into frames of at most 64 KiB**, each a
  message of its own. A receiver holds a frame until it has all of it, and a
  control frame cannot interrupt one, so the frame is kept to the write
  high-water mark.
- **Inbound, a frame may be up to 1 MiB.** NIO buffers a frame whole before
  any of it is delivered, so that is what a peer can make one connection hold
  beyond a socket read, before the core's byte budgets apply.
- **Admission is reserved when the upgrade request arrives**, before it is
  granted.
- **A socket that has not finished the HTTP exchange holds no admission
  yet**, so the listener bounds those itself: 256 at once, ten seconds each.

### Punching through NATs

Two nodes behind NATs cannot dial each other. When they have met through a
node that relays, `PunchConnector` (`Sources/Ivy`) moves them to a connection
of their own.

```swift
let punch = PunchConnector(ivy: ivy, localKey: config.publicKey, forwardingTo: delegate)
// Make `punch` the node's delegate, and keep hold of it: it passes on to
// `delegate` everything but its own topic, and a node holds its delegate weakly.
try await ivy.start()
// A relayed session to an endpoint is upgraded as it appears.
```

How it works:

1. The connector stands between a node and its delegate. When a relayed
   session to an endpoint appears, the two connectors exchange addresses on
   it ([`ivy.punch/1`](wire-protocol.md#node-to-node-behind-nats-ivypunch1)).
2. Both connect at the same moment, so each one's first packet opens its own
   NAT for the other's.
3. The stream that results is given to `connect(to:over:)` at one end and
   `accept` at the other, and the direct session
   [replaces the relayed one](wire-protocol.md#moving-to-a-direct-session).

The core knows nothing of it. Where the NATs do not allow it the relayed
session stays as it was. The `log` option is told how each attempt ended, in
a line.

The relayed session comes first. A node that cannot dial a peer asks for a
route to it: see [Whom a node asks](wire-protocol.md#whom-a-node-asks).

A transport is a `PunchTransport`. `TCPPunch` is the one there is:

- Each end takes a port of the system's choosing, listens on it, and connects
  from it to the port the other named, again and again until the window
  closes.
- Both ends leave from the port the other aims at, so they can only have made
  one connection, whether the two first packets crossed (a simultaneous open)
  or one arrived after the other end's NAT had opened.
- It tells its peer the port it bound, so it needs a NAT that keeps a
  connection's port. One that gives each connection another port cannot be
  reached this way, and those peers stay relayed.
- IPv4 only.

`Punch/run.sh` checks this on Linux with network namespaces: two nodes behind
NATs that are first shown to refuse a stranger, NATs that drop and NATs that
reset what they did not ask for, and a NAT that changes ports, where the two
must stay on the relayed session.

## WebAssembly build

`IvyCore` and `IvySimulation` build for WebAssembly and give the same trace
there as natively. `Wasm/run.sh` runs the core's test suite as Wasm and
checks that a seeded network prints the same trace digest in both builds. The
shell does not build for Wasm, because SwiftNIO does not.

`Int` is 32 bits there. Two rules keep the trace the same:

- A size limit is clamped when it becomes an `Int`, never converted outright.
- Random draws go through `UInt64` (`CoreRandom.below`,
  `CoreRandom.shuffled`), never through the standard library's `Int`-based
  ranges and shuffle.

The core imports `FoundationEssentials` where it exists, not Foundation,
which keeps the binary small: full Foundation would add tens of megabytes of
Unicode data.

Building the module and using it from JavaScript is in
[Ivy in JavaScript](../Web/README.md).

## Lifecycle

- Lifecycle calls execute in order. `start()` and `stop()` are restart-safe.
- `stop` answers every request, closes every connection and drops every
  deadline in one step.
- Identifiers are never reused, so a completion from an old run names nothing
  in a newer one.
- A callback retains its exact authenticated session and cannot send a reply
  through a replacement session for the same peer.

## Tests

| Suite | Covers |
| --- | --- |
| `IvyCoreTests` | The core on virtual time: wire and session vectors, then one file per area, and `DeterminismTests` |
| `IvyTests` | The shell over real TCP |
| `IvyWebSocketTests` | The WebSocket transport |
| `Interop/run.sh` | One program built against this version and against 15.0.1, run against each other over TCP in both directions |
| `Punch/run.sh` | NAT punching, on Linux |
| `Wasm/run.sh` | The core as WebAssembly, and the JavaScript shell |

One test hook exists in the shell, `setDialEndpointRewriteForTesting`: it
redirects the shell's dial so that nodes advertising routable addresses can
run on one machine. The core never sees it.

The laws the tests hold Ivy to are the
[correctness invariants](correctness-invariants.md).
