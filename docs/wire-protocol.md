# Ivy wire protocol

What two Ivy peers send each other: the byte streams they use, the session
handshake, the record and message encodings, the limits, and the rules for
routing, Volume exchange and relay. This is the page a second implementation
is written from. Every encoding here is defined by the Swift sources named
beside it; where the two differ, the source is right.

For how the Swift implementation is built, see
[Ivy architecture](architecture.md). The rules reviewed as laws, with IDs,
are the [correctness invariants](correctness-invariants.md).

## Overview

```text
byte stream      TCP, WebSocket, WebRTC data channel, or a relayed route
  frame          u32 length, then one session record
    record       hello, finish, or an authenticated data record
      message    one tagged message: keepalive, routing, Volume, relay, application
```

- A peer is an Ed25519 public key. A session authenticates both keys.
- Records are authenticated and replay-protected. They are **not encrypted**
  and there is no forward secrecy: confidentiality belongs above or below Ivy.
- Authentication proves control of a key, never application authority.
- The session version is **9**. A version 8 peer is rejected during the
  handshake.

A *Volume* is the unit of content Ivy transfers: a root identifier and the
complete set of entries served with it. What a Volume means is defined by
[cashew](https://lattice.build/docs/protocol/cashew/); to Ivy its identifiers
and bytes are opaque.

## Primitive encodings

All integers are unsigned and big-endian.

| Name | Encoding |
| --- | --- |
| `u8`, `u16`, `u32`, `u64` | 1, 2, 4 and 8 bytes |
| `key` | 32 bytes: a valid Ed25519 public key |
| `bytes32` | 32 bytes, as they are |
| `str` | `u16` length, then that many bytes of UTF-8; at most 8,192 bytes |
| `id` | a `str` that is non-empty and ASCII (every byte below `0x80`) |
| `data` | `u32` length, then that many bytes; at most the receiver's frame cap |
| `sdata` | `u32` length, then that many bytes: the session layer's length prefix |

Identifiers (`id`) are compared byte for byte. Ivy gives them no meaning.

A message has exactly one encoding. A receiver decodes a message, encodes the
result again, and refuses the message unless the bytes are the same; trailing
bytes and out-of-range fields are refused that way (`Message.deserialize`).

## Transports

A transport is an ordered, reliable byte stream. Framing, limits, the
handshake and sessions are the same on every one.

### TCP

The stream is the TCP connection. Nothing is sent before the first frame.

### WebSocket

For a peer that cannot open a TCP connection, such as a browser. A node
listens at the path `/ivy` by default (`Sources/IvyWebSocket`).

- The socket is only a byte stream. Binary payloads are concatenated as they
  arrive, fragmented messages included; where a WebSocket message ends means
  nothing.
- A sender splits what it writes into binary messages of at most 64 KiB.
- A node accepts a WebSocket frame of up to 1 MiB. That is above what Ivy
  sends because a browser sends each message as one frame; a peer written for
  Ivy should not send messages larger than 64 KiB either.
- A text frame, a reserved bit, a frame masked the wrong way round and a frame
  over the limit each close the connection with a close frame.
- Ping is answered with pong.
- A node answers `503` to a peer it has no room for and never upgrades it,
  `404` to another path, and `426` to a request that is not a WebSocket
  upgrade.
- There is no TLS in the transport: `wss` is terminated in front of the
  listener.

The same listener answers STUN Binding requests on the same port over UDP.
The answer is the source address of the request, as XOR-MAPPED-ADDRESS.
Nothing else in STUN is implemented: no credentials, no attributes read, no
TURN.

### WebRTC data channel

Two browsers use an ordered, reliable data channel, set up by the signalling
in [`ivy.rtc/1`](#browser-to-browser-ivyrtc1). A data channel cannot be
paused, so the stream carries a credit window (`Web/src/datachannel.ts`).

Every data-channel message is at most 16 KiB and starts with a type byte:

| Type | Rest of the message |
| --- | --- |
| `0` | Up to 16,383 bytes of the stream |
| `1` | A `u32`: that many more bytes of credit granted to the peer |

- Each end starts with 1 MiB of credit and never has more than that
  outstanding.
- A receiver grants back what its reader has taken once that is a quarter of
  the window, so it holds at most 1 MiB unread.
- A peer that sends past its credit is closed.

### Relayed route

Two peers with no stream of their own run a session through a third peer.
Each record of that session travels inside a `relayPacket` message on each
end's session with the carrier. See [Relay](#relay).

## Frames

Defined in `Sources/IvyCore/Core+Links.swift`.

| Field | Encoding |
| --- | --- |
| length | `u32`, from 1 to the receiver's frame cap |
| body | that many bytes: one session record |

A length of 0 or above the cap is malformed and closes the connection. The
frame cap is in [Bounds](#bounds).

## Session records

Defined in `Sources/IvyCore/SessionProtocol.swift` (`SessionWireRecord`).
Every record starts with the four bytes `49 56 59 09` and a `u8` kind, and
ends where its fields end.

| Kind | Record | Fields after the kind |
| --- | --- | --- |
| 1 | initiator hello | `sdata` hello, 64-byte signature |
| 2 | responder hello | `sdata` hello, 64-byte signature |
| 3 | finish | `bytes32` session ID, `key` sender, `key` receiver, 64-byte signature |
| 4 | signed data | `bytes32` session ID, `u64` sequence, `sdata` payload, 64-byte signature |
| 5 | MACed data | `bytes32` session ID, `u64` sequence, `sdata` payload, 32-byte MAC |

Any other kind is malformed. A data record's sequence is never 0 and its
payload is one [message](#messages).

### Hello

| Field | Initiator hello | Responder hello |
| --- | --- | --- |
| version | `u16`, 9 | `u16`, 9 |
| route binding | `bytes32` | `bytes32`, the initiator's |
| sender | `key` initiator | `key` responder |
| receiver | `key` responder | `key` initiator |
| nonces | `bytes32` nonce | `bytes32` the initiator's nonce, `bytes32` the responder's nonce |
| metadata | `sdata`, at most 64 KiB | `sdata`, at most 64 KiB |

The route binding is 32 zero bytes on a direct stream and the route ID on a
relayed route.

### Metadata

`PeerMetadata`, the same in both hellos:

| Field | Encoding |
| --- | --- |
| listen addresses | `u16` count, at most 16; each an `sdata` host of at most 8,192 bytes of UTF-8 and a `u16` port |
| frame cap | `u32`: the largest frame body the sender accepts. **Present only when it is not 4 MiB** |

Metadata is canonical: listen addresses are unique and sorted by host, then
port; the frame cap is left out when it is the default; nothing follows. A
receiver encodes what it decoded and rejects the hello if the bytes differ.

### Signatures and the session ID

Each signature is Ed25519 by the record's sender. `D("x")` is the text `x`
after its length as a `u32`.

| Value | Computed as |
| --- | --- |
| hello signature | sign(`D("ivy.session.hello.v1")` ‖ hello) |
| session ID | SHA-256(`D("ivy.session.transcript.v1")` ‖ `sdata`(initiator hello ‖ its signature) ‖ `sdata`(responder hello ‖ its signature)) |
| finish signature | sign(`D("ivy.session.finish.v1")` ‖ session ID ‖ sender ‖ receiver) |
| data signature | sign(`D("ivy.session.data.v1")` ‖ session ID ‖ sender ‖ receiver ‖ sequence as `u64` ‖ `sdata`(payload)) |

## Handshake

```text
initiator                               responder
   | -- 1 initiator hello ----------------> |
   | <------------- 2 responder hello ----- |
   | -- 3 finish -------------------------> |
   |          session established           |
   | <-- 4/5 data records, each way ------> |
```

1. The initiator sends its hello, naming the key it means to reach.
2. The responder checks it and answers with its own hello, echoing the route
   binding and the initiator's nonce and adding a fresh nonce.
3. The initiator checks the answer, computes the session ID, sends a finish
   signed over it, and holds the session established.
4. The responder checks the finish and holds the session established.

The responder accepts an initiator hello only when:

- its signature verifies under the initiator key;
- the responder key is its own and the initiator key is not;
- the route binding is 32 zero bytes on a direct stream, or on a relayed route
  the ID of a route it accepted from that carrier for that initiator;
- its [mode](#modes) admits the initiator;
- the metadata is canonical and within its limit.

The initiator accepts a responder hello only when its signature verifies, the
route binding and nonce are the ones it sent, the responder is the key it
meant to reach, the initiator is itself, and the metadata is canonical.

Until the session is established the stream is *pending*: it is absent from
routing, delegates, content and application messages, and a data record on it
is refused. A pending handshake is given 30 seconds. After the session is
established a hello or finish record ends it.

### Two sessions with one peer

Two peers may complete two sessions at once. Both ends keep the same one, by
one rule:

1. A direct session is kept over a relayed one.
2. Between two of a kind, the session with the smaller session ID is kept,
   comparing the 32 bytes in order.

The first rule is how two peers that met through a carrier move to a
connection of their own.

## Authenticated records

After the handshake every record is a data record.

- Each direction counts its own sequence from 1. A receiver accepts a record
  only when its sequence is greater than the last it accepted, so records
  never replay; a sender never wraps the counter.
- A record binds sender, receiver, session ID, sequence and payload.
- A record that names another session, repeats a sequence, or fails its
  signature or MAC ends the session.

### From signatures to MACs

A record is signed with the sender's identity key until both sides have
exchanged X25519 shares, then MACed. This is SIGMA-style sign-then-MAC, as in
TLS 1.3, except that the shares follow the handshake instead of riding in it.

1. Each side sends a `sessionKey` message (tag 7) as its first record, signed
   like any other. The share is thereby bound to the session ID and both
   identities.
2. A side that has sent its share and received the peer's derives one
   HMAC-SHA256 key per direction and drops its private share.
3. From then on it sends MACed records (kind 5).

With D = `D("ivy.session.mac.v1")`:

- key = HKDF-SHA256(ikm: the X25519 secret, salt: session ID, info: D ‖
  sender ‖ receiver ‖ sender's share ‖ receiver's share), 32 bytes;
- MAC = HMAC-SHA256(key, D ‖ session ID ‖ sequence as a big-endian `u64` ‖
  payload).

Rules:

- There is no key confirmation beyond the first MACed record verifying.
- An all-zero secret (a low-order share) makes no keys.
- A MACed record is sent only where the same record signed would fit, so what
  fits a frame does not depend on which kind either hop of a relay uses.
- Signed records stay accepted on every session, so a peer's records in
  flight across the switch still verify.
- One sequence counts both kinds.
- A peer that sends no share keeps the session signed.

## Messages

Defined in `Sources/IvyCore/Message.swift`. A message is a `u8` tag and its
fields, with no padding.

### Keepalive and session messages

| Tag | Message | Fields |
| --- | --- | --- |
| 0 | `ping` | `u64` nonce |
| 1 | `pong` | `u64` the ping's nonce |
| 7 | `sessionKey` | `bytes32` X25519 share |

### Routing messages

| Tag | Message | Fields |
| --- | --- | --- |
| 5 | `findNode` | `data` target, exactly 32 bytes; `u64` nonce |
| 6 | `neighbors` | endpoint list; `u64` the request's nonce |

### Volume messages

| Tag | Message | Fields |
| --- | --- | --- |
| 27 | `volumeRequest` | `u64` request ID; `id` root |
| 28 | `volumeChunk` | `u64` request ID; `id` root; `u16` index; `u16` count; `u16` total entries; `u64` total bytes; `data` payload |
| 29 | `volumeBundleRequest` | `u64` request ID; `id` root |
| 30 | `volumeBundleEnd` | `u64` request ID |
| 58 | `contentUnavailable` | `u64` request ID |

### Provider record messages

| Tag | Message | Fields |
| --- | --- | --- |
| 40 | `findProviders` | `id` root; `u64` request ID |
| 41 | `providers` | `id` root; provider record list; `u64` request ID |
| 42 | `announceProvider` | `id` root; `u64` expiry, in Unix seconds |
| 43 | `webAddresses` | web address list |
| 44 | `providersWithAddresses` | `id` root; provider record list, each record followed by its web address list; `u64` request ID |

### Application messages

| Tag | Message | Fields |
| --- | --- | --- |
| 49 | `peerMessage` | `str` topic, not empty; `data` payload |

### Relay messages

| Tag | Message | Fields |
| --- | --- | --- |
| 60 | `relayOpen` | `bytes32` route ID; `key` target |
| 61 | `relayOffer` | `bytes32` route ID; `key` source |
| 62 | `relayAccept` | `bytes32` route ID; `u8` status |
| 63 | `relayReady` | `bytes32` route ID; `u8` status |
| 64 | `relayPacket` | `bytes32` route ID; `data` one session record of the relayed session |
| 65 | `relayClose` | `bytes32` route ID |

A status of 0 accepts; any other value refuses.

### Shared structures

| Name | Encoding |
| --- | --- |
| endpoint | `str` public key; `str` host; `u16` port |
| endpoint list | `u16` count, at most 256; then that many endpoints |
| provider record | an endpoint; `u64` expiry, in Unix seconds |
| provider record list | `u16` count, at most 256; then that many records |
| web address | `str` URL; `u8` flag: `0`, or `1` followed by the `key` of the peer to relay through (`via`) |
| web address list | `u16` count, at most 4; then that many web addresses |

A public key in an endpoint is text: 64 hex digits, which a receiver also
accepts in upper case or after the prefix `ed01`, and holds in lower case.

A web address URL starts with `ws://` or `wss://` and has something after
it, is at most 256 bytes, and holds only printable ASCII (`0x21` to `0x7e`).
A list that breaks these rules does not decode.

A request ID is never 0.

### Retired tags

Tags 26 and 50 are retired and are never reused.

### Unknown and malformed messages

- A message whose tag the receiver does not know is **ignored**: the session
  stays up and nothing is recorded against the peer. Its signature or MAC and
  its sequence are still checked and its bytes counted as received.
- A known message that does not decode ends the session as a signed protocol
  violation.

## Versioning

The session version changes only when an existing record or message changes.
Everything else is an addition, and an addition needs no version:

- An addition is a new message tag. An existing message never changes its
  encoding or its meaning.
- Ivy sends a new message only to a session its caller names. Whether a peer
  speaks it is the application's to learn (its own hello) and to tell Ivy by
  naming the peer; Ivy's hello carries no capabilities.
- The exceptions are `sessionKey` and `webAddresses` (tag 43), which Ivy
  sends to every session itself: one side has to speak first. A peer that
  sends `webAddresses` has said it speaks `providersWithAddresses` (tag 44).

An ignored message costs what any message costs before it is understood. It
is bounded as every message is, by the negotiated frame size and the inbound
byte budget, and it is cheaper than a known message nobody wanted.

## Bounds

Limits a peer can rely on, and must respect. Names in `code` are `IvyConfig`
fields; the fixed ones are in `Sources/IvyCore/MessageLimits.swift`.

### Frames and metadata

| Limit | Value |
| --- | --- |
| Frame body a node accepts (its frame cap) | 4 MiB by default, `protocolMaxFrameSize`; advertised in its hello |
| Frame body a node sends | never above the cap the peer advertised; on a relayed route also never above the carrier connection's negotiated size |
| Session metadata | 64 KiB, on every route |
| `str` | 8,192 bytes |
| Listen addresses in metadata | 16 |
| Endpoints or provider records in one message | 256 |
| Web addresses a peer advertises | 4, each at most 256 bytes |

Inbound framing is checked against the node's own cap.

### Inbound bytes

- One connection may hold at most two maximum frame bodies plus a header
  (2·cap + 4).
- One node-wide budget covers bytes received in partial frames, relayed
  records and queued records: 64 MiB by default, `maxInboundBufferedBytes`.
- When a budget is exhausted a direct connection is not read until bytes are
  released, so the transport holds the sender. A relayed connection, which
  cannot be held back on its own, is closed. Neither blames the peer.
- A connection's records are handled in order, one at a time. A record the
  application is still handling holds the next, and the connection is not
  read meanwhile.

### Volume limits

| Limit | Value |
| --- | --- |
| One Volume's archive | 64 MiB |
| Entries in one Volume | 65,535 |
| Chunks in one Volume | 1,024 |
| Partial Volumes being received, node-wide | 128 MiB, `maxInFlightVolumeBytes` |
| Volume requests served at once, to all peers | 64, `maxConcurrentContentRequests` |
| Volume requests in flight to one peer | 16, `maxOutstandingVolumeRequestsPerPeer` |

- A partial assembly reserves its declared size from the node-wide receive
  cap. A source's read reserves the same bounded capacity, so concurrent
  serving cannot multiply the per-Volume limit.
- Local and remote content callbacks share one concurrency cap. A callback
  that ignores cancellation keeps its slot until it exits.

### Connections and work

- Inbound capacity is reserved by a global limit (`maxConnections`, 256) and
  a per-netgroup limit (`maxConnectionsPerNetgroup`, 2) before a connection
  is read. Capacity is a hard cap: excess peers are rejected, and an
  authenticated connection is never evicted by reputation.
- Strings, collections, connections, netgroups, pending requests, waiters,
  candidates, routing entries, provider hints and relay routes are bounded.
- A dial keeps its connection-cap reservation until it is reported ended,
  including across stop and restart.

## Modes

`IvyConfig.mode` decides which messages a node acts on.

| Mode | Admits | Runs |
| --- | --- | --- |
| `overlay` | Any peer | Everything on this page |
| `pinned(peer:)` | One endpoint identity | Everything but public discovery |
| `privateNetwork` | Any authenticated direct peer | Keepalive and application messages only. Volume messages (27 to 30, 58) too when `privateContentExchangeEnabled` is set |

A private-network node drops every other message without ending the session.
It does not run discovery, routing, provider records, relay or broadcast, and
it sends no `webAddresses`.

## Keepalive

A node pings a session that has been quiet for `keepaliveInterval` (60
seconds by default) and answers every `ping` with a `pong` carrying its
nonce. A session quiet for `staleTimeout` (180 seconds), or one that misses
`maxMissedPongs` (3) answers in a row, is closed.

## Peer discovery

Overlay mode finds peers with an authenticated Kademlia (`Router.swift`,
`Core+Routing.swift`).

- A peer's position is the SHA-256 of its public key as lower-case hex text.
  A lookup's target is the SHA-256 of the key or root identifier looked up.
  Distance is XOR.
- `findNode` carries the 32-byte target. The answer is `neighbors`: up to
  `kBucketSize` (20) of the closest peers the answerer has sessions with,
  and the request's nonce. An answer with no matching request is dropped.
- There is no peer-exchange protocol.

### Referrals and admission

- Referrals are lookup candidates, not routing entries. Only a successful
  authenticated session puts an endpoint into routing.
- Address scope, mode, identity work, connection capacity and netgroup policy
  apply before admission.
- A referral must use a globally routable IP.
- A private or loopback self-advertisement is usable only when it exactly
  matches the observed socket address.
- STUN contributes an observed host only. Configure `externalAddress` with an
  IP literal when the externally reachable TCP port differs from `listenPort`.

### Walks

Announcing and fresh discovery walk the network the way libp2p's Kademlia DHT
and BitTorrent's BEP 5 do, over the messages above.

- A walk is an iterative `findNode` for the root. It ends when the
  `kBucketSize` closest peers that answered have all been asked.
- A peer that times out or leaves drops out of the result. A referral naming
  a route not yet tried brings it back, once per walk.
- A search is one walk that asks every peer it queries for providers in the
  same round. It ends when the walk and those answers end.
- However many providers early answers name, the walk still reaches the peers
  nearest the root.
- Searches for one root share one walk.

`providerReach` chooses what walks may do:

| Value | Behaviour |
| --- | --- |
| `.walk` (default) | Dials peers not yet connected: at most `maxProviderWalkSessions` open or being dialed, and never into `reservedOutboundConnectionSlots` |
| `.connectedPeers` | Walks only among sessions already open and dials no one |

A session a walk dialed is an ordinary session. `Ivy.isProviderWalkSession`
tells the caller which ones they are; keeping or closing them is the caller's
choice.

## Provider records

A provider record says "this peer says it holds this root". It is an expiring
routing hint, not proof of possession, validity, pinning or authority.

- A record is what a peer announced for itself or what a lookup answer
  referred. A peer that served content is not recorded as a provider.
- A record's expiry must be in the future and at most `maxProviderTTLSeconds`
  (24 hours) ahead; otherwise it is not kept.
- Hints are bounded: a quota for each source and a ceiling on the table. A
  source's referrals never evict an announcement.
- A failed local dial does not erase a hint, and a failed address does not
  suppress a healthy address for the same identity.

### Announcing

- An announcement walks to the root's closest peers and tells those that
  answered (`announceProvider`). If none did, it tells the closest peers
  already connected.
- Announcing a root again while its walk runs updates the expiry that walk
  sends.
- A receiver stores every valid announcement, within the quota and ceiling.
- `stopProviding` drops the node's own record and any announcement not yet
  sent. Records already sent expire on their own: the wire has no withdrawal.
- Ivy does not republish. When and how often to announce a root again is the
  caller's choice.

### Finding providers

`findProviders` is answered with the records held for the root:

- to a peer that has sent `webAddresses` (tag 43), with
  `providersWithAddresses` (tag 44);
- to any other peer, with `providers` (tag 41).

An answer too large for the asker's frame size drops the last records'
addresses, then the last records.

### Web addresses

A peer may advertise up to four web addresses: `ws://` or `wss://` URLs a
browser can dial, for a peer that cannot dial a TCP endpoint.

- An address without `via` is where the peer itself listens. One with `via`
  says "connect to peer `via` at this URL and relay through it".
- Every session is sent the node's set (`webAddresses`) when it opens, empty
  if none, and again whenever the set changes. What a peer sent last replaces
  what it sent before.
- A provider's own records are answered with the addresses it sent last, kept
  once per provider however many records it holds. A node's own records carry
  its own.
- A record referred by an answer keeps the addresses it came with. The same
  endpoint referred with other addresses is another route beside it, so a
  referral cannot replace a provider's addresses.
- A referred record whose endpoint the endpoint policy refuses (a private or
  loopback host) is kept when it carries web addresses, for those alone. Ivy
  never dials that endpoint; `discoverProviders` and the `providers` answer
  never name it; only `discoverProviderAddresses` and tag 44 do. Without
  addresses the record is dropped.
- Addresses are the advertiser's unauthenticated claim, as a record's
  endpoint is: the dialer proves the key when it connects. They play no part
  in which records are kept, evicted or counted, and are bounded with the
  records that carry them.

### Advertising relays automatically

A node with no addresses of its own may advertise relays instead, as libp2p's
AutoRelay does. It is off by default, and a declared list always wins.

With `setAutoRelay(true)` and no declared addresses, the node advertises up
to four addresses: one for each direct session the application marked with
`setRelaying` whose peer advertised an address without `via`, as that address
with `via` the relay.

- Half the slots keep their relay while it remains a candidate, taken by the
  first relays in the current list.
- The rest go to the candidates first by SHA-256 of this node's key then the
  relay's.

So no key can be ground to be every node's relay, nodes spread over relays,
and relays that arrived first cannot hold every slot. A node targeted by
relays whose keys were ground to rank first for it can still advertise only
those; at worst browsers cannot reach it, as when a relay refuses to relay,
and nothing it advertises is corrupted.

The choice is made again when a session opens or a relay's ends, a relay's
addresses change, or `setRelaying`, `setAutoRelay` or the declared addresses
change. Sessions are told only when the result changes:

- a change other peers caused is told at most once every 10 seconds, the
  latest state when the interval ends;
- `setWebAddresses` and `setAutoRelay` take effect at once;
- a new session is told once.

## Volume exchange

### Requesting one Volume

A `volumeRequest` names only its root. The answer is the Volume's
`volumeChunk`s in order, or `contentUnavailable`.

The provider builds one archive of the complete Volume (`VolumeArchive` in
`Sources/IvyCore/ContentTypes.swift`):

| Field | Encoding |
| --- | --- |
| count | `u16`, from 1 to 65,535 |
| entries | for each: `id` identifier, `data` bytes |

Entries are in strictly ascending order of identifier, the root's own entry
is among them, and nothing follows the last.

The archive is cut into chunks. Every `volumeChunk` of one answer carries the
same request ID, root, count, total entries and total bytes; `index` runs
from 0 to count − 1; the payloads joined in order are the archive.

A chunk's payload is what is left of the frame after exact overhead:

| Subtracted | Bytes |
| --- | --- |
| The data record around the message | 113 |
| On a relayed route, the `relayPacket` envelope and the carrier's data record | 37 + 113 |
| The chunk's own fields | 29 + the root's length |

Each frame obeys the route's negotiated cap.

### Receiving

- Competing providers assemble independently.
- A replaced session, a gap, a duplicate, conflicting stream metadata or a
  malformed archive discards only that provider's attempt.
- Nothing is returned until one archive is complete and contains the
  requested root. Ivy never follows links or returns a partial Volume.
- Ivy neither validates content addressing nor interprets or traverses a DAG:
  the caller validates every identifier and byte before storage.

### Serving and time limits

- A request waiting for capacity never times out.
- `requestTimeout` (15 seconds by default) starts once a Volume request holds
  both its slot and its byte reservation. Its authorization callback runs
  before that, untimed. From then Ivy cancels serving at the deadline.
- Blocked writers release their reservation. A storage callback that ignores
  cancellation remains counted until it exits.

### Serving under load

Ivy serves any authenticated peer and never rate-limits its own requests.

- With a free slot and nobody waiting, a request is served at once.
- When requests wait for a slot, freed slots are shared among the waiting
  peers in proportion to their standing in the ledger (Tally in production).
  A peer with none still advances.
- Standing rises by bytes the peer paid for and by verified content it served
  this node, and falls by the Volume archive bytes this node served it,
  contended or not.
- Ivy does not evict an authenticated connection by score. Evidence decays.

### Bundles

A `volumeBundleRequest` names a root and asks for every Volume the source
bundles under it. It is sent only to the sessions `fetchVolumeBundle` is
given.

- The source names the bundle's Volume roots, the root's own first. What a
  bundle means is the application's.
- Ivy authorizes, reads, reserves, times and streams each Volume exactly as a
  requested one, in turn, then sends `volumeBundleEnd`.
- Between two Volumes the request gives up its serving slot and queues for
  the next. Under contention a bundle is served no faster than the same
  Volumes requested one at a time.
- A Volume that cannot be sent is left out.
- An end with no Volume before it says the peer holds no bundle for the root,
  which is distinct from `contentUnavailable`.

The requester keeps every Volume completed before the answer ended, however
it ended, each counted against its in-flight Volume budget until the fetch
returns. A bundle is never required to be complete: the caller fetches what
it still lacks as single Volumes. The result says whether the answer ended
with the peer's end marker; whether to ask again a peer whose answer did not
is the caller's to decide.

### Where a fetch looks

A Volume fetch asks, in order:

1. the node's own source;
2. known providers;
3. the peers already connected;
4. fresh discovery.

`requestTimeout` bounds each request of it; there is no deadline over the
whole fetch. A local read that is cancelled remains counted until it exits.

### Deficient content

The caller may report content deficient after validating it. Ivy then
suppresses that peer briefly for that root. It does not create peer-global
blame, close the connection, or affect messages and other roots. A later
fetch can use another connected provider, fresh discovery or fallback.

## Relay

A *carrier* is a peer that forwards a session's records between two peers
that have no stream of their own. It grants transport only.

### Opening a route

```text
source                    carrier                    target
  | -- relayOpen(id, target) -> |                        |
  |                             | -- relayOffer(id, source) -> |
  |                             | <-- relayAccept(id, status) - |
  | <-- relayReady(id, status) - |                        |
  | == handshake and records, each inside relayPacket(id, …) == |
```

1. The source picks a 32-byte route ID and sends `relayOpen` to a carrier.
2. A carrier that relays (`relayEnabled`) and has a direct session with the
   target sends it `relayOffer`. Otherwise it answers `relayReady` with a
   non-zero status at once.
3. The target answers `relayAccept`, status 0 to accept.
4. The carrier passes the result to the source as `relayReady`.
5. The source starts the [handshake](#handshake) on the route, with the route
   ID as the route binding. The first record on a route must be the offered
   peer's initiator hello.

`relayClose` from either end closes the route, and the carrier tells the
other end. A route is set up within `relayTimeout` (5 seconds by default),
and a carrier retires a route idle for 300 seconds. A node holds at most 64
routes, 8 with one peer.

### Whom a node asks

Outbound relay initiation asks, in order:

1. the node's configured carriers;
2. connected peers the application said relay (`setRelaying`), at most four
   for one connect, in key order.

One with no session to the target says so at once, and the next is asked.

- A peer is asked only if it was said to relay, because one that does not
  takes the request as a violation and ends the session.
- What was said of a peer is forgotten with its session.
- Peers do not say in the handshake whether they relay. That is for the
  application to learn, in its own first message for one.

### What a route grants

- A target may accept an inbound route offered by another authenticated
  direct peer without configuring that peer as its carrier.
- The route grants transport only. Endpoint records remain signed or MACed
  end to end, so the offer cannot change either endpoint identity or place
  the carrier in endpoint routing.
- A carrier forwards each route in arrival order to its exact destination
  session, waits only until `requestTimeout` for writability, and then
  retires that route.

### Configured carriers

Endpoint and carrier identities are disjoint: a key configured as a carrier
is never an endpoint peer.

Being a carrier is the configuring node's own choice, which the carrier
cannot see: to it, that node is one more peer to query and gossip to. So a
node takes only keepalives and relay control from a configured carrier and
drops whatever else it sends, without ending the session or blaming it.

### Moving to a direct session

Two peers that met through a carrier can move to a connection of their own.

1. One of them supplies a stream (`connect(to:over:)`); the other accepts it.
2. The handshake runs on it beside the relayed session.
3. The direct session replaces the relayed one, by the rule in
   [Two sessions with one peer](#two-sessions-with-one-peer), and the route
   through the carrier is closed.

What the application sees:

- It hears `peerConnected` for the new session and no disconnect.
- The end that started the handshake finishes first, so its close of the
  route can reach the other end before the handshake's last record does. That
  end holds the disconnect, and reports it only if the handshake then fails.
- Records in flight on the relayed session when it is replaced are not
  resent.
- If the handshake fails the stream is closed and the relayed session stays.
  `connect` still reports the peer connected, so the caller reads the
  session's route to tell which it has.

## Violations and attribution

A session is one availability zone, not a verdict about the peer.

| Event | Effect |
| --- | --- |
| Invalid authentication, a signed protocol violation, hard bound exhaustion | The session is closed |
| Application timeout, unavailable content, caller-reported deficiency | The session stays open |
| Timeout, failed dial, unavailable content, local queue pressure | Route or service state; not a violation |

Ivy attributes a violation to a peer only after verifying that peer's
signature, or the session MAC for the peer's direction, which only the two
ends hold and only the peer uses.

- A signed or MACed malformed endpoint payload remains attributable through
  a relay.
- Unsigned bytes are unattributed.
- A replay or sequence failure on a relayed route is ambiguous, because a
  carrier can replay a valid record, and is unattributed.

## Signalling formats

Two formats travel as `peerMessage`s on a relayed session, to set up a direct
stream. The core knows neither: connectors above it take the topic and the
application never sees it. Both share these rules:

- The peer with the smaller public key is the offerer, always. The other
  asks with a request, so two peers that start at once make one connection.
- Signalling counts only on the relayed session to an endpoint that is the
  peer's session now. From a direct session or a carrier it is dropped.
- One attempt per peer at a time, and three for one relayed session.
- An attempt that fails leaves the relayed session as it was. Nothing about
  signalling ends a session.

Signalling is as authentic as the relayed session: its records are signed or
MACed end to end, so the carrier can drop or delay an offer but not forge
one. It is not what authenticates the new stream. The handshake runs over
the stream as over any other: the offerer accepts only the key it meant to
reach, and the answerer learns the key of whoever is there. Whoever carried
the signalling, a session exists only with a peer that proved its key over
the stream itself.

### Node to node, behind NATs: `ivy.punch/1`

Defined in `Sources/Ivy/PunchConnector.swift`. A message is a `u8` kind, a
`u32` naming the attempt, and a body:

| Kind | Meaning | Attempt | Body |
| --- | --- | --- | --- |
| 0 | request: "offer to me" | 0 | none |
| 1 | offer | the offerer's choice, not 0 | the offerer's candidates |
| 2 | answer | the offer's | the answerer's candidates |
| 3 | sync: "connect now" | the offer's | none |
| 4 | abandon | the offer's | none |

Candidates are a `u8` count of 1 to 8, then for each:

| Field | Encoding |
| --- | --- |
| transport | `u8`: 1 TCP, 2 QUIC |
| port | `u16` |
| host | `u8` length, then UTF-8 text of at most 64 bytes |

Rules:

- The offerer also starts the handshake over the stream, whichever end the
  connection was made from.
- The offerer measures the round trip from its offer to the answer, sends
  the sync, and waits half of it before connecting, so both start together.
- A candidate is dialled only if it is a public address and of a transport
  this node has. A peer names its own addresses, and without that it could
  aim a dial at a host inside this node's network.
- A relayed session busy with something else has no room for a message at
  the moment it is sent. The signalling waits for room while its attempt
  lasts.
- At most eight attempts run at once. An attempt takes at most eight
  messages of at most 1 KiB, both ends dial for six seconds, and it ends
  after fifteen, or when its peer abandons it, or on anything malformed.

### Browser to browser: `ivy.rtc/1`

Defined in `Web/src/rtc.ts`. A message is a `u8` kind, a `u32` naming the
attempt, and UTF-8 text to the end:

| Kind | Meaning | Attempt | Text |
| --- | --- | --- | --- |
| 0 | request: "offer to me" | 0 | none |
| 1 | offer | the offerer's choice, not 0 | SDP |
| 2 | answer | the offer's | SDP |
| 3 | candidate | the offer's | one ICE candidate line, for the only media section |
| 4 | abandon | the offer's | none |

Rules:

- An offer from the peer with the larger key is dropped.
- A message for another attempt is dropped.
- An attempt takes at most 64 messages of at most 8 KiB and sends at most 64
  candidates.
- An attempt ends after 20 seconds, or when its peer abandons it, or on
  anything malformed: an unknown kind, a description or candidate the browser
  refuses, an answer nobody asked for. Its peer connection is closed.
- When the channel opens the offerer starts the handshake on it and the
  answerer accepts it.
- There is no TURN: a carrier already relays for peers with no path to each
  other.

Each peer learns the address the other can reach it at by STUN, asking the
carrier its relayed session runs through, at the address it reached that
carrier's WebSocket. No one else is asked, and the carrier already sees that
address. Peers whose NATs give no usable address this way stay on the relayed
session.

## Upgrading and older peers

- **Version 8.** Version 9 introduced multi-frame Volume replies, which
  cannot safely share the older one-frame Volume contract, so a version 8
  peer is rejected during authentication.
- **Unknown tags.** Every Ivy2 peer (2.0.0 on) ignores a tag it does not
  know. Peers through 14.0.0 end the session on one, which is why a new
  message is sent only to a session the caller names.
- **Web addresses.** A peer that never sent `webAddresses` is answered with
  `providers` (tag 41), so it never sees tag 44.
- **Two sessions with one peer.** A peer on 15.x keeps the smaller session
  ID whatever the route, so the two ends can disagree and drop the session.
  Only move to a direct session toward a peer on the rule above.
