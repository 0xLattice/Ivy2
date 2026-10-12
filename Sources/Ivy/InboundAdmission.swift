import Foundation
import IvyCore

/// Bounds inbound connections that have been admitted and not yet reported
/// to the core, so a flood of accepts cannot queue without limit. Once the
/// core has seen a connection it counts it itself.
final class InboundAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConnections: Int
    private let maxConnectionsPerNetgroup: Int
    private var accepting = true
    private var count = 0
    private var countsByNetgroup: [String: Int] = [:]

    init(maxConnections: Int, maxConnectionsPerNetgroup: Int) {
        self.maxConnections = maxConnections
        self.maxConnectionsPerNetgroup = maxConnectionsPerNetgroup
    }

    func reserve(observedHost: String?) -> InboundAdmissionLease? {
        let netgroup = NetGroup.group(observedHost ?? "unknown")
        return lock.withLock {
            guard accepting,
                  count < maxConnections,
                  countsByNetgroup[netgroup, default: 0] < maxConnectionsPerNetgroup else {
                return nil
            }
            count += 1
            countsByNetgroup[netgroup, default: 0] += 1
            return InboundAdmissionLease(gate: self, netgroup: netgroup) { [weak self] in
                self?.release(netgroup: netgroup)
            }
        }
    }

    func invalidate() {
        lock.withLock { accepting = false }
    }

    var isAccepting: Bool { lock.withLock { accepting } }

    private func release(netgroup: String) {
        lock.withLock {
            count -= 1
            let remaining = countsByNetgroup[netgroup, default: 0] - 1
            countsByNetgroup[netgroup] = remaining > 0 ? remaining : nil
        }
    }
}

/// One reserved inbound connection slot, from `Ivy.reserveInboundAdmission`.
/// The slot is freed when the node has taken the connection it admitted, when
/// that connection closes first, or when an unused lease is dropped.
public final class InboundAdmissionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (() -> Void)?
    private var claimed = false
    /// The gate that issued this lease and the netgroup it counted; a lease
    /// admits only a stream of that netgroup, into that gate's run.
    private(set) weak var gate: InboundAdmissionGate?
    let netgroup: String

    init(gate: InboundAdmissionGate, netgroup: String, release: @escaping () -> Void) {
        self.gate = gate
        self.netgroup = netgroup
        releaseAction = release
    }

    /// A lease admits one connection: true only for its first caller.
    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    func release() {
        let action = lock.withLock { () -> (() -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }

    deinit { release() }
}
