# Event codec

`IvyCore.step` takes an `Event` and returns `[Effect]`. A host that cannot
hold those Swift values, such as JavaScript driving the core as WebAssembly,
passes them as the bytes described here. This is not the wire protocol: it
never leaves the machine, and it is versioned on its own.

Two implementations exist and must agree: `Sources/IvyCore/EventCodec.swift`
and `Web/src/codec.ts`. `Web/test/vectors.json` holds an encoding of every
case. The Swift suite regenerates it and fails if the checked-in file differs
(`IVY_UPDATE_VECTORS=1 swift test --filter EventCodecTests` rewrites it); the
TypeScript suite decodes and re-encodes every vector and must get the same
bytes.

## Primitives

All integers are big-endian, like the wire codec.

| Name | Encoding |
| --- | --- |
| `u8`, `u16`, `u32`, `u64` | Unsigned, 1, 2, 4 and 8 bytes |
| `i64` | Two's complement, 8 bytes |
| `bool` | One byte, `0` or `1` |
| `bytes` | `u32` length, then that many bytes, as they are |
| `string` | `bytes` holding UTF-8 |
| `key` | 32 bytes: an Ed25519 public key |
| `size` | `i64`. The core holds it as an `Int` and clamps it to one, so `Int.max` from a 64-bit host is still "no limit" where `Int` is 32 bits |
| `duration` | `i64` seconds, `i64` attoseconds: Swift's `Duration.components` |
| `optional<T>` | `bool`, then `T` if it was `1` |
| `list<T>` | `u32` count, then that many `T` |

A payload costs its own length plus four bytes; nothing is escaped or
re-encoded, so megabytes pass through as they are.

Every encoding starts with one version byte, currently `1`, and holds exactly
one value: bytes after its end are an error. A change to anything below is a
new version.

Decoding takes untrusted bytes and refuses, without trapping:

- an unknown version or tag, and a `bool` that is neither `0` nor `1`;
- input that ends early, including a length or count larger than what is
  left, which is compared as a `u32` before it becomes an `Int`;
- a `string` that is not valid UTF-8 (a byte-order mark is kept, not dropped);
- a `duration` that is not what `components` reports: attoseconds outside
  ±10^18, or of the other sign than the seconds;
- Volume entries not in strictly ascending order, and listen addresses not in
  the order `PeerMetadata` keeps them.

So a value has one encoding, with one exception: a peer ID is normalised as
`PeerID` normalises it, so an `ed01`-prefixed or upper-case key decodes to the
bare lower-case one.

## Shared structures

| Name | Fields |
| --- | --- |
| `endpoint` | `string` publicKey, `string` host, `u16` port |
| `address` | `string` host, `u16` port |
| `peerID` | `string`: the public key in hex |
| `route` | `u8` tag: `0` direct; `1` relayed, then `key` carrier, `bytes` routeID |
| `peer` (`AuthenticatedPeer`) | `key`, `u8` role (`0` endpoint, `1` carrier), `route`, `list<address>` listenAddresses, `u32` maxFrameSize, `bytes` sessionID |
| `failure` | `optional<u8>`: `0` callerBoundaryExceeded, `1` localCapacityUnavailable, `2` notSent |
| `volume` | `string` rootCID, `list<(string cid, bytes data)>` in ascending order of the identifiers' UTF-8 bytes, `optional<peerID>` servedBy, `failure` |

## Event

`version`, then a `u8` tag and its fields.

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `start` | |
| 1 | `stop` | |
| 2 | `tick` | |
| 3 | `connectionOpened` | `u64` connection, direction (`u8` `0` inbound; `1` outbound, then `u64` dial), `optional<string>` observedHost, `optional<string>` localHost |
| 4 | `dialFailed` | `u64` dial |
| 5 | `received` | `u64` connection, `bytes` |
| 6 | `writable` | `u64` connection |
| 7 | `closed` | `u64` connection |
| 8 | `request` | `u64` request, then a request (below) |
| 9 | `cancel` | `u64` request |
| 10 | `command` | a command (below) |
| 11 | `delivered` | `u64` token |
| 12 | `jobFinished` | `u64` job, then a job result (below) |
| 13 | `publicAddress` | `optional<address>` |

### Request

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `connect` | `endpoint` |
| 1 | `connectOver` | `endpoint`, `u64` connection, `optional<string>` observedHost, `optional<string>` localHost |
| 2 | `connectViaRelay` | `endpoint` |
| 3 | `send` | `peerID` to, `string` topic, `bytes` payload |
| 4 | `sendOnSession` | `peer`, `string` topic, `bytes` payload |
| 5 | `waitUntilWritable` | `peerID` |
| 6 | `waitUntilSessionWritable` | `peer` |
| 7 | `fetchVolume` | `string` rootCID, `size` maximumArchiveBytes, `size` maximumEntries |
| 8 | `fetchVolumeFrom` | `peer`, `string` rootCID, `size` maximumArchiveBytes, `size` maximumEntries |
| 9 | `fetchVolumeBundle` | `string` rootCID, `list<peer>` from |
| 10 | `findNode` | `string` target |
| 11 | `discoverProviders` | `string` rootCID |
| 12 | `recycleSession` | `peer` |
| 13 | `disconnectSession` | `peer` |

### Command

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `disconnect` | `peerID` |
| 1 | `restartConfiguredSession` | `peerID` |
| 2 | `broadcast` | `string` topic, `bytes` payload |
| 3 | `announceProvider` | `string` rootCID, `u64` expiresAt |
| 4 | `reportDeficientContent` | `string` rootCID, `peerID` servedBy |
| 5 | `setContentSource` | `bool` |

### Job result

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `entries` | `list<(string cid, bytes data)>`, in the order given |
| 1 | `roots` | `list<string>` |
| 2 | `authorized` | `bool` |

## Effect

`version`, then a `u8` tag and its fields. What one step returned is
`version`, then `list<effect>` with no version byte before each.

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `dial` | `u64` dial, `endpoint` |
| 1 | `write` | `u64` connection, `bytes` |
| 2 | `close` | `u64` connection |
| 3 | `pauseReading` | `u64` connection |
| 4 | `resumeReading` | `u64` connection |
| 5 | `deliver` | `u64` token, `peer`, `string` topic, `bytes` payload |
| 6 | `peerConnected` | `u64` token, `peer` |
| 7 | `peerDisconnected` | `peerID` |
| 8 | `publicAddressDiscovered` | `address` |
| 9 | `completed` | `u64` request, then a request result (below) |
| 10 | `startJob` | `u64` job, then a job (below) |
| 11 | `cancelJob` | `u64` job |
| 12 | `discoverPublicAddress` | |
| 13 | `wakeAt` | `duration` |

### Job

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `readVolume` | `string` rootCID, `size` maxDataBytes |
| 1 | `readVolumeBundle` | `string` rootCID |
| 2 | `authorizeVolume` | `peer`, `string` rootCID |

### Request result

| Tag | Case | Fields |
| --- | --- | --- |
| 0 | `connect` | `u8` outcome: `0` connected; `1` failed, then `u8` error; `2` cancelled |
| 1 | `send` | `u8` result: `0` enqueued, then `peerID` endpoint, `route`; `1` backpressured; `2` notConnected; `3` locallyRejected |
| 2 | `writable` | `bool` |
| 3 | `volume` | `volume` |
| 4 | `volumeBundle` | `list<volume>`, `bool` noBundle, `bool` ended, `failure` |
| 5 | `endpoints` | `list<endpoint>` |
| 6 | `flag` | `bool` |

Connect errors: `0` notRunning, `1` invalidPeerKey, `2` peerOutsideMode,
`3` connectionInProgress, `4` identityVerificationFailed, `5` noRelayAvailable,
`6` streamHasNoObservedHost.

## Lists the core's views return

`connectedPeers` and `providers(for:)` are `version`, `list<peerID>`.
`connectedPeerEndpoints` and `knownPeerEndpoints` are `version`,
`list<endpoint>`.

## Configuration

`IvyConfig(encoded:)` reads `version`, the 32-byte Ed25519 seed, and then
these fields in this order, each an `optional` that has `IvyConfig`'s default
when absent:

| Field | Encoding |
| --- | --- |
| `listenPort` | `u16` |
| `bootstrapPeers` | `list<endpoint>` |
| `carriers` | `list<endpoint>` |
| `relayEnabled` | `bool` |
| `mode` | `u8`: `0` overlay; `1` privateNetwork; `2` pinned, then `string` peer |
| `privateContentExchangeEnabled` | `bool` |
| `requestTimeout` | `duration` |
| `healthConfig.keepaliveInterval` | `duration` |
| `healthConfig.staleTimeout` | `duration` |
| `healthConfig.maxMissedPongs` | `size` |
| `healthConfig.enabled` | `bool` |
| `protocolMaxFrameSize` | `u32` |
| `maxConnections` | `size` |
| `maxConnectionsPerNetgroup` | `size` |
| `maxPendingRequests` | `size` |
| `maxConcurrentContentRequests` | `size` |
| `maxInboundBufferedBytes` | `size` |
| `maxInFlightVolumeBytes` | `size` |

The result names no STUN server: a host that needs this encoding has no UDP
socket, and reports an address it learns some other way with
`Event.publicAddress`. Decoding does not validate; `IvyConfig.validate()` does.
