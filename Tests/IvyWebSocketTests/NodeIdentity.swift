import Foundation
import Ivy
import Tally

/// `Ivy.localID` and `Ivy.config` are isolated to the actor, as in 15.x, so
/// reading them takes an `await`. Tests compare identities inside assertions,
/// where there is none to be had, so each node's identity is noted when it is
/// made.
private final class NodeIdentities: @unchecked Sendable {
    static let shared = NodeIdentities()
    private let lock = NSLock()
    private var keys: [ObjectIdentifier: String] = [:]

    func note(_ node: Ivy, publicKey: String) {
        lock.withLock { keys[ObjectIdentifier(node)] = publicKey }
    }

    func publicKey(of node: Ivy) -> String {
        lock.withLock { keys[ObjectIdentifier(node)] } ?? ""
    }
}

extension Ivy {
    /// Makes a node and notes its identity for `id` and `publicKey`.
    static func forTesting(_ config: IvyConfig) -> Ivy {
        let node = Ivy(config: config)
        NodeIdentities.shared.note(node, publicKey: config.publicKey)
        return node
    }

    nonisolated var publicKey: String { NodeIdentities.shared.publicKey(of: self) }
    nonisolated var id: PeerID { PeerID(publicKey: publicKey) }
}
