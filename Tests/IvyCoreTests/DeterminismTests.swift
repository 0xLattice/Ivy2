import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// The property the rewrite exists for: the same events give the same effects.
final class DeterminismTests: XCTestCase {
    /// A busy network: bootstrap, lookups, announcements, Volume fetches of
    /// announced and unannounced roots, churn and a partition, all on one seed.
    private func runScenario(seed: UInt64) -> (digest: String, effects: Int, served: Int) {
        let sim = Simulation(seed: seed)
        let seedNode = sim.node(health: PeerHealthConfig(
            keepaliveInterval: .seconds(20), staleTimeout: .seconds(60)))
        var nodes = [seedNode]
        for _ in 0..<11 {
            nodes.append(sim.node(
                bootstrap: [seedNode.endpoint],
                health: PeerHealthConfig(keepaliveInterval: .seconds(20), staleTimeout: .seconds(60))))
        }
        sim.run(for: .seconds(5))

        for (index, node) in nodes.enumerated() where index % 3 == 0 {
            node.volumes["root-\(index)"] = volumeEntries(root: "root-\(index)", members: 2, bytesEach: 2_000)
            node.volumes["vol-\(index)"] = volumeEntries(root: "vol-\(index)", members: 6, bytesEach: 30_000)
            sim.send(.command(.announceProvider(
                rootCID: "vol-\(index)", expiresAt: sim.unixSeconds + 3_600)), to: node)
        }
        var lookups: [(Simulation.Node, RequestID)] = []
        for node in nodes.dropFirst() {
            lookups.append((node, sim.request(.findNode(target: node.key.hex), on: node)))
        }
        sim.run(for: .seconds(40))

        var fetches: [(Simulation.Node, RequestID)] = []
        for (index, node) in nodes.enumerated() where index % 3 == 1 {
            let source = (index - 1)
            fetches.append((node, sim.request(.fetchVolume(
                rootCID: "vol-\(source)", maximumArchiveBytes: .max, maximumEntries: .max), on: node)))
            fetches.append((node, sim.request(.fetchVolume(
                rootCID: "root-\(source)", maximumArchiveBytes: .max, maximumEntries: .max), on: node)))
        }
        sim.run(for: .seconds(20))

        // Churn: one node leaves, two are cut off from each other, one returns.
        sim.stop(nodes[5])
        sim.setPartitioned(true, nodes[2], nodes[7])
        sim.run(for: .seconds(90))
        sim.start(nodes[5])
        sim.setPartitioned(false, nodes[2], nodes[7])
        sim.run(for: .seconds(150))

        let served = fetches.filter { node, request in
            switch sim.result(of: request, on: node) {
            case .volume(let response)?: return !response.entries.isEmpty
            default: return false
            }
        }.count
        XCTAssertEqual(lookups.filter { sim.result(of: $1, on: $0) == nil }.count, 0)
        return (sim.traceDigest, sim.trace.count, served)
    }

    func testSeededMultiNodeRunReproducesItsTrace() {
        let first = runScenario(seed: 0xC0FFEE)
        let second = runScenario(seed: 0xC0FFEE)
        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(first.effects, second.effects)
        XCTAssertGreaterThan(first.effects, 2_000, "the scenario must exercise the network")
        XCTAssertGreaterThan(first.served, 0)
    }

    func testDifferentSeedsGiveDifferentTraces() {
        XCTAssertNotEqual(runScenario(seed: 1).digest, runScenario(seed: 2).digest)
    }

    /// Hash ordering differs between processes, so a digest that is stable
    /// within one process can still drift between two. CI pins the seed and
    /// compares this value across separate runs of the test binary.
    func testSeededTraceDigestIsPrinted() {
        let seed = ProcessInfo.processInfo.environment["IVY_TEST_SEED"]
            .flatMap { UInt64($0.dropFirst($0.hasPrefix("0x") ? 2 : 0), radix: $0.hasPrefix("0x") ? 16 : 10) }
            ?? 0x5EED
        let result = runScenario(seed: seed)
        print("IVY_TRACE_DIGEST seed=\(seed) effects=\(result.effects) digest=\(result.digest)")
    }

    /// Replaying a recorded event log into a fresh core gives the recorded effects.
    func testCoreReplaysItsEventLog() {
        let key = Simulation(seed: 9).signingKey(index: 0)
        let peerKey = Simulation(seed: 9).signingKey(index: 1)
        let config = IvyConfig(
            signingKey: key,
            bootstrapPeers: [PeerEndpoint(
                publicKey: IvyConfig(signingKey: peerKey).publicKey, host: "8.8.0.1", port: 4001)],
            stunServers: [])
        func makeCore() -> IvyCore {
            IvyCore(
                config: config,
                scheme: SimulatedSignatureScheme(key: config.peerKey),
                random: .seeded(42))
        }
        func at(_ seconds: Int64) -> Timestamp {
            Timestamp(uptime: .seconds(seconds), unixSeconds: 1_800_000_000 + UInt64(seconds))
        }
        let log: [(Event, Timestamp)] = [
            (.start, at(0)),
            (.dialFailed(DialID(2)), at(1)),
            (.tick, at(2)),
            (.connectionOpened(ConnectionID(7), direction: .inbound, observedHost: "8.9.0.1", localHost: "8.1.0.1"), at(3)),
            (.received(ConnectionID(7), Data([0, 0, 0, 5, 1, 2, 3, 4, 5])), at(4)),
            (.request(RequestID(1), .findNode(target: "abc")), at(5)),
            (.request(RequestID(2), .fetchVolume(rootCID: "root", maximumArchiveBytes: 1_000, maximumEntries: 10)), at(6)),
            (.tick, at(40)),
            (.stop, at(41)),
        ]
        var first = makeCore()
        var second = makeCore()
        var produced = 0
        for (event, time) in log {
            let a = first.step(event, now: time)
            let b = second.step(event, now: time)
            XCTAssertEqual(a, b)
            produced += a.count
        }
        XCTAssertGreaterThan(produced, 5)
        XCTAssertEqual(first.diagnostics, second.diagnostics)
    }
}
