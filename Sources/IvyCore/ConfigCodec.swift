@preconcurrency import Crypto
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public extension IvyConfig {
    /// A configuration from bytes, for a host that cannot build the Swift
    /// value; the format is in docs/event-codec.md. Every field but the key
    /// may be left out and then has this type's default. The result has no
    /// STUN servers: such a host has no UDP socket to ask one with, and
    /// reports an address it learns some other way as `Event.publicAddress`.
    /// Nil for bytes that are not a configuration; `validate()` still decides
    /// whether a configuration is usable.
    init?(encoded bytes: Data) {
        let decoded = EventCodec.decode(bytes) { reader -> IvyConfig in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: try reader.fixed(32))
            let defaults = IvyConfig(signingKey: key)
            let health = defaults.healthConfig
            let listenPort = try reader.optional { try $0.uint16() }
            let bootstrapPeers = try reader.optional { try $0.list { try $0.endpoint() } }
            let carriers = try reader.optional { try $0.list { try $0.endpoint() } }
            let relayEnabled = try reader.optional { try $0.bool() }
            let mode = try reader.optional { reader -> IvyMode in
                switch try reader.uint8() {
                case 0: return .overlay
                case 1: return .privateNetwork
                case 2: return .pinned(peer: try reader.string())
                default: throw CodecReader.Malformed()
                }
            }
            let privateContentExchangeEnabled = try reader.optional { try $0.bool() }
            let requestTimeout = try reader.optional { try $0.duration() }
            let keepaliveInterval = try reader.optional { try $0.duration() }
            let staleTimeout = try reader.optional { try $0.duration() }
            let maxMissedPongs = try reader.optional { try $0.size() }
            let healthEnabled = try reader.optional { try $0.bool() }
            let protocolMaxFrameSize = try reader.optional { try $0.uint32() }
            let maxConnections = try reader.optional { try $0.size() }
            let maxConnectionsPerNetgroup = try reader.optional { try $0.size() }
            let maxPendingRequests = try reader.optional { try $0.size() }
            let maxConcurrentContentRequests = try reader.optional { try $0.size() }
            let maxInboundBufferedBytes = try reader.optional { try $0.size() }
            let maxInFlightVolumeBytes = try reader.optional { try $0.size() }
            return IvyConfig(
                signingKey: key,
                listenPort: listenPort ?? defaults.listenPort,
                bootstrapPeers: bootstrapPeers ?? [],
                requestTimeout: requestTimeout ?? defaults.requestTimeout,
                stunServers: [],
                healthConfig: PeerHealthConfig(
                    keepaliveInterval: keepaliveInterval ?? health.keepaliveInterval,
                    staleTimeout: staleTimeout ?? health.staleTimeout,
                    maxMissedPongs: maxMissedPongs ?? health.maxMissedPongs,
                    enabled: healthEnabled ?? health.enabled),
                maxConnections: maxConnections ?? defaults.maxConnections,
                maxConnectionsPerNetgroup: maxConnectionsPerNetgroup
                    ?? defaults.maxConnectionsPerNetgroup,
                maxPendingRequests: maxPendingRequests ?? defaults.maxPendingRequests,
                maxConcurrentContentRequests: maxConcurrentContentRequests
                    ?? defaults.maxConcurrentContentRequests,
                maxInboundBufferedBytes: maxInboundBufferedBytes
                    ?? defaults.maxInboundBufferedBytes,
                maxInFlightVolumeBytes: maxInFlightVolumeBytes ?? defaults.maxInFlightVolumeBytes,
                protocolMaxFrameSize: protocolMaxFrameSize ?? defaults.protocolMaxFrameSize,
                relayEnabled: relayEnabled ?? defaults.relayEnabled,
                privateContentExchangeEnabled: privateContentExchangeEnabled
                    ?? defaults.privateContentExchangeEnabled,
                carriers: carriers ?? [],
                mode: mode ?? defaults.mode)
        }
        guard let decoded else { return nil }
        self = decoded
    }
}
