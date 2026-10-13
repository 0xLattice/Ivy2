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
| Waiting on channel writability | The core counts what it wrote since the last `writable(conn)` and holds chunk cursors, relay forwards, Volume requests and application waiters past 64 KiB. Keepalives, "not available", handshake and relay control records are still written, from a reserve of 64 KiB more, so a peer waiting on one is not left to time out while a Volume is in flight |
| Task groups in a lookup | A stored query: candidates, who was asked, the round, what is outstanding |
| A task per served request | A serving state with an explicit phase; a granted slot advances it in the same step |
| Run and operation generations | Nothing: a stopped run's state is gone, and a late event names an unknown identifier |

The shell (`Ivy`, `StreamShell`, `STUNClient`) owns everything the core does
not: connections, the single timer, STUN, calls into `IvyDelegate` and
`IvyContentSource`, and the map from request to waiting caller.

## Transports

A connection is a `TransportConnection`: an ordered, reliable byte stream that
delivers bytes only when asked, says whether it has room for more, and reports
its close once. Framing, byte budgets, admission, the handshake and sessions
are all above it and the same for every stream. TCP is one supplier
(`TCPStream`) and takes the same path as any other.

Whoever establishes a stream hands it to Ivy:

- inbound, `reserveInboundAdmission(observedHost:)` then `accept(_:admission:)`.
  The lease is taken before anything is spent on the peer, admits one stream of
  the netgroup it was reserved for, and belongs to the run that issued it.
- outbound, `connect(to:over:)`. The stream is closed unless it becomes the
  peer's session, and there is no falling back to another route or a carrier.

A stream must report the host its peer was observed at: netgroup admission
keys on it. Its address is not one Ivy can dial, so it is kept out of routing
unless the peer advertises a listen address of its own.

### WebSocket

`IvyWebSocket` supplies streams over WebSocket, for a peer that cannot open a
TCP connection: a browser. It is a separate product, so a node that does not
want it does not build it. `WebSocketTransport` listens and dials for one
`Ivy`, and hands each upgraded connection over by the two calls above.

Ivy frames its own records, so the socket is used only as an ordered byte
stream. Binary payloads are concatenated as they arrive, fragmented messages
included, and where a message ends means nothing. A text frame, a reserved bit,
a frame masked the wrong way round and a frame over the limit each close the
connection with a close frame. Ping is answered with pong, the latest only if
the peer is not reading its answers.

- Outbound, a record is split into frames of at most 64 KiB, each a message of
  its own. A receiver holds a frame until it has all of it, and a control frame
  cannot interrupt one, so the frame is kept to the write high-water mark.
- Inbound, a frame may be up to 1 MiB. NIO buffers a frame whole before any of
  it is delivered, so that is what a peer can make one connection hold beyond a
  socket read, before the core's byte budgets apply. It is above what Ivy sends
  because a browser sends each message as one frame; a peer written for Ivy
  should not send messages larger than 64 KiB either.
- Reads are pulled as on TCP: the socket is not read unless the core asked for
  bytes, so a connection held back leaves its data in the kernel. Control
  frames are behind that data, so a ping is answered when the connection is
  next read, not while it is held.
- Admission is reserved when the upgrade request arrives and before it is
  granted. A refused peer gets `503` and is never upgraded; another path gets
  `404`, and a request that is not a WebSocket upgrade `426`.
- A socket that has not finished the HTTP exchange holds no admission yet, so
  the listener bounds those itself: 256 at once, ten seconds each.

There is no TLS in this target. `wss` is terminated in front of the listener,
by a reverse proxy or a load balancer. Behind one, every socket comes from the
proxy, so `trustForwardedFor` takes the peer's address from the last hop of
`X-Forwarded-For`, the one the proxy itself wrote, and refuses a request
without it. Enable it only behind a proxy that sets the header and that
nothing can bypass: the address decides netgroup admission, and a peer that
reaches the listener directly would choose its own. It is off by default.

The listener also answers STUN Binding requests, on the same port over UDP,
unless `listen` is told `stun: false`. A page asks it for its own address
before connecting to another page; see Browser to browser. The answer is the
source address of the request, as XOR-MAPPED-ADDRESS, and nothing else in
STUN is implemented: no credentials, no attributes read, no TURN.

- UDP does not pass through the proxy that terminates `wss`. The page asks at
  the host and port it dialled, so UDP to that port must reach this one.
- The source of a request is not verified, so an answer can be aimed at
  someone who did not ask. It is 32 bytes for a request of 20 or more (44 over
  IPv6), and one node sends at most 20 a second to one address (one IPv6 /64)
  and answers at most 4096 addresses in a second.

The listener does not look at `Origin`. Any page may open a socket, as any
peer may open a TCP connection; what it can do is decided by the session
handshake.

The other end in a page is `Web/src/websocket.ts`, over the browser's own
WebSocket. That one cannot be read on request: every message is handed over
as it arrives, so a connection the core holds back is not held in the kernel
there but in a queue in the page. A peer there cannot be slowed, only
dropped: the stream closes when 128 MiB waits unread. It sends messages of
at most 64 KiB, and delivers at most that much for each request.

The core also builds for WebAssembly, where `Int` is 32 bits, and gives the
same trace there as natively. Two rules keep that true: a size limit is
clamped when it becomes an `Int`, never converted outright, and random draws
go through `UInt64` (`CoreRandom.below`, `CoreRandom.shuffled`), never through
the standard library's `Int`-based ranges and shuffle. The core imports
`FoundationEssentials` where it exists, not Foundation.

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

Outbound relay initiation uses configured carriers, and after them the
connected peers the application said relay (`setRelaying`), at most four for
one connect, in key order. One with no session to the target says so at
once, and the next is asked. A peer is asked only if it was said to relay
because one that does not takes the request as a violation and ends the
session; what was said of a peer is forgotten with its session. Peers do
not say in the handshake whether they relay, so that is for the application
to learn, in its own first message for one. A target may accept an
inbound route offered by another authenticated direct peer without configuring
that peer as its carrier. The route grants transport only: endpoint records
remain signed end to end, so the offer cannot change either endpoint identity
or place the carrier in endpoint routing. A carrier forwards each route in
arrival order to its exact destination session, waits only until
`requestTimeout` for writability, and then retires that route.

Two peers that met through a carrier can move to a connection of their own.
One of them supplies a stream to `connect(to:over:)`: the handshake runs
beside the relayed session, and the direct session it makes replaces it. Both
ends choose the same way, by one rule: a direct session is kept over a relayed
one, and between two of a kind the smaller session ID is kept. The
application hears `peerConnected` for the new session and no disconnect, and
the route through the carrier is closed. The end that started the handshake
finishes first, so its close of the route can reach the other end before the
handshake's last record does; that end holds the disconnect, and reports it
only if the handshake then fails. Records in flight on the relayed
session when it is replaced are not resent. If the handshake fails the stream
is closed and the relayed session stays; `connect` still reports the peer
connected, so the caller reads the session's route to tell which it has. A
peer on 15.x keeps the smaller ID whatever the route, so the two ends can
disagree and drop the session: only upgrade toward a peer on this rule.

Being a carrier is the configuring node's own choice, which the carrier cannot
see: to it, that node is one more peer to query and gossip to. So a node takes
only keepalives and relay control from a configured carrier and drops whatever
else it sends, without ending the session or blaming it.

Ivy attributes a violation only after verifying the charged peer's signature.
Signed malformed endpoint payloads remain attributable through relay. Unsigned
bytes are unattributed, and relay-controlled replay or sequence failure is
ambiguous because a carrier can replay a valid record.

Timeouts, failed dials, unavailable content, and local queue pressure remain
route or service state, not protocol violations.

## Node to node, behind NATs

Two nodes that cannot be dialled reach each other the same way two browsers
do, with another kind of stream. `PunchConnector` (`Sources/Ivy`) stands
between a node and its delegate. When a relayed session to an endpoint
appears, the two connectors exchange addresses on it, as peer messages on the
topic `ivy.punch/1`, and then both connect at the same moment. Each one's
first packet opens its own NAT for the other's. The stream that results is
given to `connect(to:over:)` at one end and `accept` at the other, and the
direct session replaces the relayed one as above. The core knows nothing of
it.

A signalling message is one byte of kind, a big-endian `u32` naming the
attempt, and a body:

| Kind | | Attempt | Body |
| --- | --- | --- | --- |
| 0 | request: "offer to me" | 0 | none |
| 1 | offer | the offerer's choice, not 0 | the offerer's candidates |
| 2 | answer | the offer's | the answerer's candidates |
| 3 | sync: "connect now" | the offer's | none |
| 4 | abandon | the offer's | none |

Candidates are a count of 1 to 8, then for each its transport (1 TCP, 2
QUIC), its port as a big-endian `u16`, and its host as a length byte and
UTF-8 text of at most 64 bytes.

- The peer with the smaller public key offers, always; the other asks. It is
  also the one that starts the handshake over the stream, whichever end the
  connection was made from.
- The offerer measures the round trip from its offer to the answer, sends
  the sync, and waits half of it before connecting, so both start together.
- A candidate is dialled only if it is a public address and of a transport
  this node has. A peer names its own addresses, and without that it could
  aim a dial at a host inside this node's network.
- Signalling counts only on the relayed session to an endpoint that is the
  peer's session now; anything else on the topic is dropped, and the
  application never sees the topic.
- One attempt per peer at a time, three for one relayed session, eight at
  once. An attempt takes at most eight messages of at most 1 KiB, both ends
  dial for six seconds, and it ends after fifteen, or when its peer abandons
  it, or on anything malformed. The relayed session is left as it was.
  Nothing about signalling ends a session.

A transport is a `PunchTransport`. `TCPPunch` is the one there is: each end
takes a port of the system's choosing, listens on it, and connects from it
to the port the other named, again and again until the window closes. Both
ends leave from the port the other aims at, so they can only have made one
connection, whether the two first packets crossed (a simultaneous open) or
one arrived after the other end's NAT had opened. It tells its peer the
port it bound, so it needs a NAT that keeps a connection's port; one that
gives each connection another port cannot be reached this way, and those
peers stay relayed. IPv4 only.

`Punch/run.sh` checks this on Linux with network namespaces: two nodes
behind NATs that are first shown to refuse a stranger, NATs that drop and
NATs that reset what they did not ask for, and a NAT that changes ports,
where the two must stay on the relayed session.

## Browser to browser

Two browsers reach each other over a WebRTC data channel, which `Web/` sets up
(`src/rtc.ts`, `src/datachannel.ts`) and the core knows nothing of: to it the
channel is one more supplied stream. Both are connected to a carrier, and one
opens a relayed session to the other. Offer, answer and ICE candidates then
travel on that session as peer messages on the topic `ivy.rtc/1`. When the
channel opens the offerer gives it to `connect(to:over:)` and the answerer to
`accept`, and the direct session replaces the relayed one as above. There is
no TURN: a carrier already relays for peers with no path to each other.

Two peers behind different NATs each need the address the other can reach
them at, which a browser learns only by STUN. Each asks the carrier its
relayed session runs through, at the address it reached that carrier's
WebSocket: no one else is asked, and the carrier already sees that address.
Peers whose NATs give no usable address this way stay on the relayed session.

A signalling message is one byte of kind, a big-endian `u32` naming the
attempt, and UTF-8 text to the end:

| Kind | | Attempt | Text |
| --- | --- | --- | --- |
| 0 | request: "offer to me" | 0 | none |
| 1 | offer | the offerer's choice, not 0 | SDP |
| 2 | answer | the offer's | SDP |
| 3 | candidate | the offer's | one ICE candidate line, for the only media section |
| 4 | abandon | the offer's | none |

- The peer with the smaller public key is the offerer, always. The other asks
  with a request, and an offer from it is dropped, so two peers that start at
  once make one connection.
- Signalling counts only when it arrives on the relayed session to an endpoint
  that is the peer's session now. From a direct session or a carrier it is
  dropped. Either way the application never sees the topic.
- One attempt per peer at a time, and three for one relayed session. A message
  for another attempt is dropped. An attempt takes at most 64 messages of at
  most 8 KiB and sends at most 64 candidates.
- An attempt ends after 20 seconds, or when its peer abandons it, or on
  anything malformed: an unknown kind, a description or candidate the browser
  refuses, an answer nobody asked for. Its peer connection is closed and the
  relayed session is left as it was. Nothing about signalling ends a session.
- The peer connection is closed when its stream closes, when the peer
  disconnects, and when the connector is closed.

Signalling is as authentic as the relayed session: its records are signed end
to end, so the carrier can drop or delay an offer but not forge one. It is
not what authenticates the channel. The core's handshake runs over the
channel as over any stream: the offerer accepts only the key it meant to
reach, and the answerer learns the key of whoever is there, as on any stream
it accepts. Whoever carried the signalling, a session exists only with a peer
that proved its key over the channel itself.

The end that completes the handshake first closes the relayed session. The
other end can hear of that through the carrier before the handshake's last
record reaches it over the channel; the core holds that disconnect, so each
application hears only `peerConnected` for the direct session.

A data channel delivers whatever its peer sends and cannot be paused, so the
transport adds a credit window. Every data-channel message is at most 16 KiB,
the size all browsers exchange, and starts with a type byte: `0` and up to
16 383 bytes of the stream, or `1` and a big-endian `u32` granting that many
more bytes. Each end starts with 1 MiB of credit and never has more than that
outstanding. A receiver hands bytes over only as the core asks, at most
64 KiB at a time, and grants back what was taken once that is a quarter of
the window; so it holds at most 1 MiB unread, and a peer that sends past its
credit is closed. A sender regains credit once a round trip at best, so the
window is what one round trip carries: 1 MiB keeps a 100 ms path above
10 MiB/s. The stream is writable while it has credit and the channel's own
buffer is under 256 KiB.

The observed host is the remote address of the selected ICE candidate pair.
A browser often hides that address, behind an mDNS name of its own choosing
or behind nothing; a name says nothing of where a peer is and the peer picks
it, so the stream is then given `<peer key>.webrtc.invalid`, for the key the
signalling was signed by. `NetGroup` puts a host that is not an address in a
group of its own, so such peers are admitted and do not share a netgroup; the
netgroup limit does not bound them, and `maxConnections` does.

## Lifecycle

Lifecycle calls execute in order. `stop` answers every request, closes every
connection and drops every deadline in one step; identifiers are never reused,
so a completion from an old run names nothing in a newer one. A callback
retains its exact authenticated session and cannot send a reply through a
replacement session for the same peer.

See [correctness-invariants.md](correctness-invariants.md) for the normative
review laws.
