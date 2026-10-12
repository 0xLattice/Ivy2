# Architecture

Ivy turns an untrusted byte stream into bounded records attributed to peer keys.
Authentication proves key control, not application authority.

```text
caller: authority, validation, storage, protocol meaning
                         |
Ivy (shell): sockets, one timer, delegate and storage calls
                         |   events in, effects out
IvyCore: admission, sessions, routing, content, relay
```

## Core and shell

Every decision Ivy makes is made by `IvyCore`, a value with one entry point:

```swift
mutating func step(_ event: Event, now: Timestamp) -> [Effect]
```

Events are everything that can happen to Ivy: a connection opened, bytes
arrived, a connection can be written again, time passed (`tick`), the
application asked for something, a storage job finished. Effects are everything
Ivy wants done: dial, write, close, stop or resume reading a connection, deliver
a message, start or cancel a storage job, answer a request, and `wakeAt`, the
earliest deadline it holds. The core never waits, reads a clock, opens a socket,
starts a task or draws randomness it was not given, so the same events at the
same times always give the same effects. `IvyCoreTests` asserts this on a
multi-node run, and the same seed gives the same trace in separate processes.

What the old implementation expressed with `await` is state in the core:

| Was | Is |
| --- | --- |
| 13 one-shot timers and 2 repeating ones | One deadline table; `tick` expires what has passed, and each step emits one `wakeAt` |
| Awaiting the delegate inline | `deliver(token, …)`; the connection's next record is held, and the connection not read, until `delivered(token)` |
| A lock-shared inbound byte budget | Counters charged as bytes join a frame and released when its record has been handled; exhaustion emits `pauseReading`, release emits `resumeReading` |
| Waiting on channel writability | The core counts what it wrote since the last `writable(conn)` and holds chunk cursors, relay forwards and application waiters past 64 KiB |
| Task groups in a lookup | A stored query: candidates, who was asked, the round, what is outstanding |
| A task per served request | A serving state with an explicit phase; a granted slot advances it in the same step |
| Run and operation generations | Nothing: a stopped run's state is gone, and a late event names an unknown identifier |

The shell (`Ivy`, `TCPShell`, `STUNClient`) owns everything the core does not:
TCP sockets, the single timer, STUN, calls into `IvyDelegate` and
`IvyContentSource`, and the map from request to waiting caller. A transport
needs four things to carry Ivy: ordered bytes in, ordered bytes out, a way to
stop and resume reads, and a signal that what was written has drained. TCP is
the one supplied; the core knows nothing about it.

Signatures, traffic evidence and randomness are injected (`IvySignatureScheme`,
`PeerLedger`, `CoreRandom`). Production uses Ed25519, Tally and the system
generator. `IvySimulation` uses repeatable stand-ins, because a session ID
covers both handshake signatures and decides which of two simultaneous
sessions survives.

## Connections

Inbound capacity is reserved by global and netgroup limits before a connection
is read: the shell reports a new connection unread, and the core answers with
`resumeReading` or `close`. Rejected sockets cannot buffer protocol input. Capacity is a hard cap: Ivy rejects excess peers rather than evicting
an authenticated connection by reputation.

A pending socket is absent from routing, delegates, content, and application
messages. Promotion requires a signed transcript over both identities, fresh
nonces, route binding, and bounded metadata, followed by the initiator's signed
finish.

Application records bind sender, receiver, session ID, sequence, and payload.
Receive sequences strictly increase. Simultaneous sessions for one peer and
role converge on the smaller session ID. Records are signed but not encrypted;
confidentiality and forward secrecy belong above or below Ivy.

Wire/session protocol v9 rejects v8 during authentication. V9 introduces
multi-frame complete-Volume replies, which cannot safely share the older
one-frame Volume contract.

### Adding to the wire without a new version

The session version changes only when an existing record or message changes.
Everything else is an addition, and an addition needs no version:

- An addition is a new message tag. An existing message never changes its
  encoding or its meaning.
- Ivy sends a new message only to a session its caller names. Whether a peer
  speaks it is the application's to learn (its own hello) and to tell Ivy by
  naming the peer; Ivy's hello carries no capabilities.
- A message whose tag this version does not know is ignored: the session
  stays up and nothing is recorded against the peer. A known message that
  does not decode still ends the session as a signed protocol violation.

An ignored message costs what any message costs before it is understood: its
signature and sequence are checked and its bytes counted as received. It is
bounded as every message is, by the negotiated frame size and the inbound
byte budget, and it is cheaper than a known message nobody wanted. Peers that
predate this rule (through 14.0.0) end the session on an unknown tag, which is
why the second point is a rule and not a courtesy.

Treat every authenticated endpoint connection as an independent availability
zone, not a verdict about the peer. Application timeouts, unavailable content,
and caller-reported deficiency leave the session open. Only transport safety
failures such as invalid authentication, signed protocol violations, or hard
bound exhaustion close it.

## Bounds

- Each node advertises the maximum frame body it will accept (inbound) in its
  handshake; the default is 4 MiB and it is operator-tunable via
  `protocolMaxFrameSize`. A node never sends a frame larger than the peer
  advertised it will accept, and on a relayed route it is further capped at the
  carrier connection's negotiated size. Inbound framing is validated against the
  node's own local cap.
- Each connection's inbound byte budget scales with the local frame cap: it may
  hold at most two maximum frame bodies plus a header (2·cap + 4). One node-wide
  byte budget also covers bytes actually received in partial frames, relayed
  records, and queued records; its default is 64 MiB and is operator-tunable via
  `maxInboundBufferedBytes`. Exhaustion stops reading a direct connection until
  bytes are released, so TCP holds the sender; a relayed connection, which
  cannot be held back on its own, is closed. Neither blames the peer.
- Canonical session metadata is limited to 64 KiB.
- Strings, collections, connections, netgroups, pending requests, waiters,
  candidates, routing entries, provider hints, and relay routes are bounded.
- Framing overhead is subtracted from each Volume chunk before it is framed.
- A complete Volume is at most 64 MiB and 65,535 members. Its ordered chunks
  share one request, root, authenticated endpoint session, and node run; partial
  assemblies reserve their declared size from a 128 MiB node-wide receive cap.
  Source materializations pessimistically reserve the same bounded capacity, so
  concurrent serving cannot multiply the per-Volume limit.
- A connection's records are handled in order, one at a time; a record the
  application is still handling holds the next, and the connection is not read
  meanwhile. Local and remote content callbacks share one concurrency cap; a
  callback that ignores cancellation keeps its slot until it actually exits.
- A physical dial keeps its connection-cap reservation until the shell reports
  how it ended, including across stop and restart.

Ivy serves any authenticated peer and never rate-limits its own requests.
Tally records peer-global traffic evidence and compares peers only when
content requests wait for a serving slot: waiting peers share freed slots in
proportion to the verified content they served this node, and a peer with no
history still advances. Ivy does not evict an authenticated connection by
score. Evidence decays, and application content deficiency remains root-scoped
rather than becoming global blame.

## Application protocols

Ivy's generic records and Volume exchange are enough to compose gossip,
sync, and retrieval. Broadcast messages announce gossip to current peers;
directed messages carry sync control; Volume requests retrieve the bytes. Gossip identity, deduplication, forwarding, sync semantics, CID
validation, and storage remain caller policy.

## Routing and content

Overlay mode uses correlated `findNode` responses from authenticated Kademlia
peers. Address scope, mode, identity work, connection capacity, and netgroup
policy apply before admission. Referrals are lookup candidates, not routing
entries; only a successful authenticated session promotes an endpoint into
routing. Private-network mode exposes only authenticated direct messages; it
does not run discovery, routing, provider, content, relay, or broadcast services.
A referral must use a globally routable IP. A private or loopback
self-advertisement is usable only when it exactly matches the observed socket
address. Pinned mode admits one endpoint identity. Ivy has no peer-exchange
protocol. STUN contributes an observed host only; configure `externalAddress`
with an IP literal when the externally reachable TCP port differs from
`listenPort`.

Identifiers are non-empty ASCII wire strings, so equality is byte-exact without
assigning them semantics.

A Volume request names only its root. The source returns one complete bounded
Volume, which Ivy canonically orders and streams in sequential frames. Each
frame still obeys the same negotiated route cap (4 MiB by default). Competing providers assemble
independently, and replacement sessions, gaps, duplicates, conflicting stream
metadata, and malformed archives discard only that provider's attempt. Ivy
returns no `AttributedVolumeResponse` until one archive is complete and contains
the requested root. Identifiers and bytes remain opaque: Ivy neither validates
content addressing nor interprets or traverses a DAG. A request waiting for
capacity never times out. `requestTimeout` starts once a Volume request holds
both its slot and its byte reservation (its authorization callback runs before that, untimed); from then
Ivy cancels serving at the deadline. Blocked writers release their reservation, while a storage
callback that ignores cancellation remains counted until it actually exits.

A bundle request (added after v9 under the rule above, so sent only to the
sessions `fetchVolumeBundle` is given) names a root and asks for every Volume
the source bundles under it. The source names the bundle's Volume roots, the root's own first;
what a bundle means is the application's. Ivy authorizes, reads, reserves,
times and streams each Volume exactly as a requested one, in turn, then sends
`volumeBundleEnd`. Between two Volumes the request gives up its serving slot
and queues for the next, so under contention a bundle is served no faster
than the same Volumes requested one at a time. A Volume that cannot
be sent is left out; an end with no Volume before it says the peer holds no
bundle for the root, which is distinct from `contentUnavailable`. The
requester keeps every Volume completed before the answer ended, however it
ended, each counted against its in-flight Volume budget until the fetch
returns: a bundle is never required to be complete, and the caller fetches
what it still lacks as single Volumes. The result says whether the answer
ended with the peer's end marker; whether to ask again a peer whose answer did
not is the caller's to decide.

A Volume fetch asks the node's own source, then known providers, then the
peers already connected, then fresh discovery. `requestTimeout` bounds each
request of it; there is no deadline over the whole fetch. A local read that is
cancelled remains counted until it exits. Provider hints are bounded and expiring: each is a peer's own announcement or a
referral from a lookup answer, never a note that a peer served the root; a
source's referrals never evict an announcement. A failed local dial
does not erase a hint, and a failed address does not suppress a healthy address
for the same identity.

The caller may report content deficient after validation. Ivy then suppresses
that peer briefly for that root; it does not create peer-global blame, close the
connection, or affect messages and other roots. A later fetch can use another
connected provider, fresh discovery, or fallback as a separate availability
zone.

## Relay and attribution

Outbound relay initiation uses configured carriers. A target may accept an
inbound route offered by another authenticated direct peer without configuring
that peer as its carrier. The route grants transport only: endpoint records
remain signed end to end, so the offer cannot change either endpoint identity
or place the carrier in endpoint routing. A carrier forwards each route in
arrival order to its exact destination session, waits only until
`requestTimeout` for writability, and then retires that route.

Ivy attributes a violation only after verifying the charged peer's signature.
Signed malformed endpoint payloads remain attributable through relay. Unsigned
bytes are unattributed, and relay-controlled replay or sequence failure is
ambiguous because a carrier can replay a valid record.

Timeouts, failed dials, unavailable content, and local queue pressure remain
route or service state, not protocol violations.

## Lifecycle

Lifecycle calls execute in order. `stop` answers every request, closes every
connection and drops every deadline in one step; identifiers are never reused,
so a completion from an old run names nothing in a newer one. A callback
retains its exact authenticated session and cannot send a reply through a
replacement session for the same peer.

See [correctness-invariants.md](correctness-invariants.md) for the normative
review laws.
