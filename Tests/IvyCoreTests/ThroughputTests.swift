import Crypto
import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

/// How fast one single-stepped core moves a maximum Volume. Printed, not
/// asserted against a number: it answers whether stepping is the limit.
final class ThroughputTests: XCTestCase {
    private func transfer(realSignatures: Bool) -> (seconds: Double, steps: Int, megabytes: Double) {
        let sim = Simulation(seed: 3)
        func config(_ key: Curve25519Key) -> IvyConfig {
            IvyConfig(signingKey: key, stunServers: [], healthConfig: PeerHealthConfig(enabled: false))
        }
        let a = sim.addNode(realSignatures: realSignatures, configure: config)
        let b = sim.addNode(realSignatures: realSignatures, configure: config)
        sim.start(a)
        sim.start(b)
        // Just under the 64 MiB archive limit.
        let entries = [ContentEntry(cid: "vol", data: Data(repeating: 1, count: 1024))]
            + (0..<63).map { ContentEntry(cid: "vol-\($0)", data: Data(repeating: UInt8($0), count: 1024 * 1024)) }
        b.volumes["vol"] = entries
        sim.connect(a, b)

        let before = sim.trace.count
        let started = Date()
        let response = sim.await(
            .fetchVolume(rootCID: "vol", maximumArchiveBytes: .max, maximumEntries: .max), on: a)?.volume
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(response?.entries.count, entries.count)
        sim.run(for: .seconds(1))
        XCTAssertEqual(b.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(a.core.diagnostics.inFlightVolumeBytes, 0)
        let bytes = entries.reduce(0) { $0 + $1.data.count }
        return (elapsed, sim.trace.count - before, Double(bytes) / 1_048_576)
    }

    func testMaximumVolumeThroughCore() {
        for real in [false, true] {
            let result = transfer(realSignatures: real)
            let rate = result.megabytes / max(result.seconds, 0.000_001)
            print(String(
                format: "IVY_THROUGHPUT signatures=%@ %.0f MiB in %.3fs = %.0f MiB/s, %d effects",
                real ? "ed25519" : "simulated", result.megabytes, result.seconds, rate, result.steps))
        }
    }
}

private typealias Curve25519Key = Crypto.Curve25519.Signing.PrivateKey
