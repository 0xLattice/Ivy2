import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Small replies and keepalives are still written while a link is past the
/// mark that holds bulk data back.
final class ControlRecordHeadroomTests: XCTestCase {
    private func fetch(_ root: String) -> Request {
        .fetchVolume(rootCID: root, maximumArchiveBytes: .max, maximumEntries: .max)
    }

    /// While `b` streams a large Volume to `a`, its link to `a` is past the
    /// mark most of the time. Its "I do not have that" for another root must
    /// not be dropped, leaving `a` to wait out its request timeout.
    func testANegativeAnswerIsNotLostBehindAVolumeBeingServed() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        b.volumes["big"] = volumeEntries(root: "big", members: 24, bytesEach: 1_000_000)
        sim.connect(a, b)
        guard let session = a.core.authenticatedPeer(for: b.peer) else { return XCTFail("no session") }

        let big = sim.request(fetch("big"), on: a)
        var answered: [Duration] = []
        for index in 0..<20 {
            sim.run(for: .milliseconds(2))
            let asked = sim.now
            let absent = sim.request(
                .fetchVolumeFrom(session, rootCID: "absent-\(index)", maximumArchiveBytes: .max, maximumEntries: .max),
                on: a)
            sim.run(until: { sim.result(of: absent, on: a) != nil })
            answered.append(sim.now - asked)
            if sim.result(of: big, on: a) != nil { break }
        }
        XCTAssertGreaterThan(answered.count, 3, "the Volume finished before the test could ask beside it")
        let slowest = answered.max() ?? .zero
        XCTAssertLessThan(slowest, .seconds(1), "answers took \(answered)")
        sim.run(until: { sim.result(of: big, on: a) != nil })
        XCTAssertEqual(sim.result(of: big, on: a)?.volume?.entries.count, 25)
    }

    /// A peer that stops reading and keeps asking is answered from the
    /// reserve only until the reserve is spent: what is queued for it stays
    /// bounded.
    func testTheReserveIsBoundedForAPeerThatStopsReading() {
        let sim = Simulation()
        let node = sim.node()
        let peer = HandPeer(sim, to: node, index: 1, host: "10.1.0.1")
        XCTAssertTrue(peer.authenticate())
        sim.run(for: .seconds(1))
        sim.setRawStalled(true, peer.connection, at: node)
        sim.saturate(node, toward: peer.id)

        func written() -> Int {
            sim.trace.reduce(0) { total, entry in
                guard entry.node == node.id, case .write(_, let bytes) = entry.effect else { return total }
                return total + bytes.count
            }
        }
        let before = written()
        for index in 0..<4_000 {
            peer.send(Message.volumeRequest(requestID: UInt64(index + 1), rootCID: "absent-\(index)"))
        }
        sim.run(for: .seconds(1))
        let fromReserve = written() - before
        XCTAssertGreaterThan(fromReserve, 0, "the first answers are written")
        XCTAssertLessThan(fromReserve, IvyCore.writeHighWaterMark + 1_024, "and then no more")
        XCTAssertFalse(peer.isClosed)
    }
}
