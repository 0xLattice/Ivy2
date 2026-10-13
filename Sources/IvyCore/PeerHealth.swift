#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct PeerHealthConfig: Sendable {
    public let keepaliveInterval: Duration
    public let staleTimeout: Duration
    public let maxMissedPongs: Int
    public let enabled: Bool

    public init(
        keepaliveInterval: Duration = .seconds(60),
        staleTimeout: Duration = .seconds(180),
        maxMissedPongs: Int = 3,
        enabled: Bool = true
    ) {
        self.keepaliveInterval = keepaliveInterval
        self.staleTimeout = staleTimeout
        self.maxMissedPongs = maxMissedPongs
        self.enabled = enabled
    }

    public static let `default` = PeerHealthConfig()
}

/// Keepalive state for one authenticated session.
struct PeerHealth: Sendable, Equatable {
    let sessionID: SessionID
    var lastActivity: Duration
    var pendingPingNonce: UInt64?
    var missedPongs = 0
}
