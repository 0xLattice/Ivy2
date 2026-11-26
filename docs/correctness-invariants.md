# Ivy correctness invariants

The laws Ivy must keep, each with a stable ID that code, tests and reviews
cite. The behaviour behind them is specified in the
[wire protocol](wire-protocol.md).

Authentication proves a peer key, never application authority.

| ID | Law |
| --- | --- |
| IVY-001 | Inbound capacity is reserved before protocol reads begin. |
| IVY-002 | Pending sockets are invisible to routing, delegates, content, and application messages. |
| IVY-003 | Promotion requires the complete route-bound signed handshake and bounded canonical metadata. |
| IVY-004 | Accepted records bind sender, receiver, session, sequence, and payload; sequences never replay or wrap. |
| IVY-005 | Duplicate sessions for one peer and role converge on one: a direct session is kept over a relayed one, and between two of a kind the smaller session ID is kept. |
| IVY-006 | Endpoint and carrier identities are disjoint; carriers never enter endpoint routing. |
| IVY-007 | Work from an old run, operation, or authenticated session cannot mutate or reply through successor state. |
| IVY-008 | Frames, fields, connections, pending work, routing, hints, routes, and all partial or queued inbound bytes are bounded. |
| IVY-009 | Each node enforces its own frame-body cap (4 MiB default, operator-tunable, handshake-advertised); outbound never exceeds the peer's advertised cap (carrier-minimum on relay). One 64 KiB metadata cap applies on every route. |
| IVY-010 | Exact route overhead is removed from every Volume chunk before it is framed. |
| IVY-012 | Ivy treats non-empty ASCII wire identifiers and bytes as opaque and never traverses or stores a DAG. |
| IVY-014 | Provider records are expiring hints and grant no possession, validity, or authority. |
| IVY-015 | Public discovery returns admitted candidates; only authenticated promotion installs routing state, and there is no PEX. |
| IVY-016 | Outbound relay initiation uses configured carriers, and after them the connected peers the application said relay; inbound offers grant transport only, every relayed session authenticates both endpoint identities end to end, and carrier forwarding is ordered, exact-session-bound, and deadline-bounded. |
| IVY-017 | Peer-global blame requires that peer's verified signature or its direction's session MAC; carrier-controlled ambiguity remains unattributed. |
| IVY-018 | Queue acceptance does not assert receipt, application acceptance, or durability. |
| IVY-019 | Authorization, content validity, storage, consensus, fees, and settlement remain above Ivy. |
| IVY-020 | Application unavailability or deficient content may change selection for that root, but cannot disconnect or globally condemn an authenticated peer. |
| IVY-021 | A complete Volume is bounded, request/root/session/run-bound, globally reservation-capped on receive and serve, sequentially assembled per provider, and visible only after exact complete decoding. |
| IVY-022 | `IvyCore` performs no I/O and reads no clock or random source it was not given: equal events at equal times give equal effects. |

## Where each law is specified

| IDs | Section |
| --- | --- |
| IVY-001, IVY-002 | [Admission](architecture.md#admission) |
| IVY-003 | [Handshake](wire-protocol.md#handshake) |
| IVY-004 | [Authenticated records](wire-protocol.md#authenticated-records) |
| IVY-005 | [Two sessions with one peer](wire-protocol.md#two-sessions-with-one-peer) |
| IVY-006, IVY-016 | [Relay](wire-protocol.md#relay) |
| IVY-007 | [Lifecycle](architecture.md#lifecycle) |
| IVY-008, IVY-009 | [Bounds](wire-protocol.md#bounds) |
| IVY-010, IVY-012, IVY-021 | [Volume exchange](wire-protocol.md#volume-exchange) |
| IVY-014 | [Provider records](wire-protocol.md#provider-records) |
| IVY-015 | [Peer discovery](wire-protocol.md#peer-discovery) |
| IVY-017, IVY-020 | [Violations and attribution](wire-protocol.md#violations-and-attribution) |
| IVY-022 | [The core](architecture.md#the-core) |

## Coverage

Coverage is in `IvyCoreTests`, on virtual time: the wire and session vectors,
then one file per area (sessions and admission, relay, routing and provider
records, serving, fetching) and `DeterminismTests`. `IvyTests` covers the
shell over real TCP.

## Retired IDs

These IDs are not reused.

- IVY-011
- IVY-013
