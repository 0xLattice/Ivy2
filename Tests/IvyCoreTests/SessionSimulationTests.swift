import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

final class SessionSimulationTests: XCTestCase {
    func testTwoNodesAuthenticateAndExchangeMessages() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        sim.connect(a, b)

        XCTAssertEqual(a.connected.map(\.id), [b.peer])
        XCTAssertEqual(b.connected.map(\.id), [a.peer])
        XCTAssertEqual(a.connected.first?.route, .direct)
        XCTAssertEqual(a.core.diagnostics.pendingSessions, 0)
        XCTAssertEqual(a.core.diagnostics.outgoingDials, 0)

        let sent = sim.await(.send(to: b.peer, topic: "greeting", payload: Data("hello".utf8)), on: a)
        XCTAssertEqual(sent?.sent, .enqueued(endpoint: b.peer, route: .direct))
        sim.run(until: { !b.received.isEmpty })
        XCTAssertEqual(b.received.first?.message, PeerMessage(topic: "greeting", payload: Data("hello".utf8)))
        XCTAssertEqual(b.received.first?.peer.id, a.peer)
    }

    func testRealSignaturesAuthenticate() {
        let sim = Simulation()
        let a = sim.addNode(realSignatures: true) {
            IvyConfig(signingKey: $0, stunServers: [], healthConfig: PeerHealthConfig(enabled: false))
        }
        let b = sim.addNode(realSignatures: true) {
            IvyConfig(signingKey: $0, stunServers: [], healthConfig: PeerHealthConfig(enabled: false))
        }
        sim.start(a)
        sim.start(b)
        sim.connect(a, b)
        XCTAssertEqual(b.connected.map(\.id), [a.peer])
    }

    func testFetchContentFromConnectedPeer() {
        let sim = Simulation()
        let a = sim.node()
        let b = sim.node()
        b.content = ["root": Data("r".utf8), "leaf": Data("l".utf8)]
        sim.connect(a, b)

        let response = sim.await(.fetchContent(rootCID: "root", cids: ["leaf"]), on: a)?.content
        XCTAssertEqual(response?.entries, ["root": Data("r".utf8), "leaf": Data("l".utf8)])
        XCTAssertEqual(response?.servedBy, b.peer)
        XCTAssertEqual(a.core.diagnostics.activeFetches, 0)
        XCTAssertEqual(b.core.diagnostics.servingSlotsHeld, 0)
    }

    func testFetchVolumeSpanningManyChunks() {
        let sim = Simulation()
        let a = sim.node(protocolMaxFrameSize: 256 * 1024)
        let b = sim.node(protocolMaxFrameSize: 256 * 1024)
        let entries = volumeEntries(root: "vol", members: 40, bytesEach: 50_000)
        b.volumes["vol"] = entries
        sim.connect(a, b)

        let response = sim.await(
            .fetchVolume(rootCID: "vol", maximumArchiveBytes: .max, maximumEntries: .max), on: a)?.volume
        XCTAssertEqual(response?.entries.count, entries.count)
        XCTAssertEqual(response?.servedBy, b.peer)
        XCTAssertEqual(response?.entries["vol-7"], entries[8].data)
        sim.run(for: .seconds(1))
        XCTAssertEqual(a.core.diagnostics.inFlightVolumeBytes, 0)
        XCTAssertEqual(a.core.diagnostics.reservedVolumeBytes, 0)
        XCTAssertEqual(b.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(b.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(a.core.diagnostics.inboundBytesUsed, 0)
    }
}
