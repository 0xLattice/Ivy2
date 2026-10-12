import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// The serving side under authorization, slots and session loss: what a
/// peer's request makes this node ask of its storage, and what it answers.
final class ContentServingSimulationTests: XCTestCase {
    private func server(
        _ sim: Simulation,
        slots: Int = 64,
        requestTimeout: Duration = .seconds(3_600)
    ) -> Simulation.Node {
        sim.node(requestTimeout: requestTimeout, maxConcurrentContentRequests: slots)
    }

    // MARK: - Authorization

    // authorization and storage use one captured source
    func testAuthorizationCannotSwapStorageSource() {
        let sim = Simulation()
        let server = server(sim)
        server.volumes["root"] = servingSmallVolume("root")
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.volumeRequest(requestID: 1, rootCID: "root"))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.volumeAuthorizations, ["root"])
        // The source goes away while it is being asked: the request it
        // authorized is still read from it.
        sim.send(.command(.setContentSource(false)), to: server)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(server.volumeReads, ["root"])
        XCTAssertEqual(peer.chunks.map(\.requestID), [1])
        XCTAssertServingIdle(server)
    }

    // authorization work obeys the inbound content cap
    func testAuthorizationObeysContentCap() {
        let sim = Simulation()
        let server = server(sim, slots: 1)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.volumeRequest(requestID: 1, rootCID: "one"))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.volumeAuthorizations, ["one"])
        // The second request waits for the slot; its authorization does not start.
        peer.send(.volumeRequest(requestID: 2, rootCID: "two"))
        sim.run(for: .milliseconds(50))
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.volumeAuthorizations, ["one"])

        // Authorization and read of the first, then the second's turn.
        sim.answerStalledJobs(server)
        XCTAssertEqual(server.volumeAuthorizations, ["one"])
        sim.answerStalledJobs(server)
        XCTAssertEqual(server.volumeAuthorizations, ["one", "two"])
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 0)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1, 2])
        XCTAssertServingIdle(server)
    }

    // private content exchange requires explicit opt-in
    func testPrivateContentExchangeRequiresOptIn() {
        let sim = Simulation()
        let disabled = sim.node(mode: .privateNetwork)
        disabled.volumes["root"] = servingSmallVolume("root")
        disabled.bundles["root"] = ["root"]
        let stranger = ServingRawPeer(sim, to: disabled, index: 1)
        stranger.send(.volumeRequest(requestID: 2, rootCID: "root"))
        stranger.send(.volumeBundleRequest(requestID: 3, rootCID: "root"))
        sim.run(for: .seconds(1))
        // Nothing is asked of storage and nothing is answered; the session stays.
        XCTAssertEqual(disabled.startedJobs.count, 0)
        XCTAssertTrue(stranger.read().isEmpty)
        XCTAssertTrue(disabled.core.connectedPeers.contains(stranger.peer))
        XCTAssertServingIdle(disabled)

        let enabled = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        enabled.authorize = { _, _ in false }
        let member = ServingRawPeer(sim, to: enabled, index: 2)
        member.send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.run(for: .seconds(1))
        member.read()
        XCTAssertEqual(enabled.volumeAuthorizations, ["root"])
        XCTAssertEqual(enabled.volumeReads.count, 0)
        XCTAssertEqual(member.unavailable, [2])
        XCTAssertServingIdle(enabled)
    }

    // With the opt-in a private node serves Volumes and bundles.
    func testPrivateNetworkServesContentWhenEnabled() {
        let sim = Simulation()
        let server = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        server.volumes["root"] = servingSmallVolume("root")
        server.bundles["root"] = ["root"]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        peer.send(.volumeBundleRequest(requestID: 3, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertNotNil(peer.archive(requestID: 2, rootCID: "root"))
        XCTAssertNotNil(peer.archive(requestID: 3, rootCID: "root"))
        XCTAssertEqual(peer.bundleEnds, [3])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
    }

    // MARK: - Slots

    // inbound storage callbacks obey the global concurrency bound
    func testInboundContentConcurrency() {
        let sim = Simulation()
        let server = server(sim, slots: 2)
        let peers = (0..<3).map { ServingRawPeer(sim, to: server, index: $0 + 1) }
        server.stallsStorage = true
        peers[0].send(.volumeRequest(requestID: 1, rootCID: "root"))
        peers[1].send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)

        // A third request waits for a slot rather than reaching storage.
        peers[2].send(.volumeRequest(requestID: 3, rootCID: "root"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.volumeAuthorizations.count, 2)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)

        sim.releaseNextRead(server)
        XCTAssertEqual(server.volumeReads.count, 3)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        for (index, peer) in peers.enumerated() {
            peer.read()
            XCTAssertEqual(peer.unavailable, [UInt64(index + 1)])
        }
        XCTAssertServingIdle(server)
    }

    // a disconnected peer retains its serving slot until storage exits
    func testDisconnectedPeerRetainsServingSlot() {
        let sim = Simulation()
        let server = server(sim, slots: 8)
        server.volumes["root"] = servingSmallVolume("root")
        let old = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        old.send(.volumeRequest(requestID: 7, rootCID: "root"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 1)
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        let oldRead = server.servingStalledJobs[0].id

        // The same peer comes back on a new connection and asks with the
        // same request ID: its own request, not a duplicate of the old one.
        old.close()
        XCTAssertEqual(server.cancelledJobs, [oldRead])
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        let replacement = ServingRawPeer(sim, to: server, index: 1)
        replacement.send(.volumeRequest(requestID: 7, rootCID: "root"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        replacement.read()
        XCTAssertEqual(replacement.unavailable, [])

        sim.answerStalledJobs(server, limit: 1, where: servingJobIsRead)
        XCTAssertEqual(server.core.servingContentRequests.count, 1)
        // The old request's bytes go nowhere.
        replacement.read()
        XCTAssertEqual(replacement.chunks.count, 0)

        sim.answerStalledJobs(server, limit: 1, where: servingJobIsRead)
        XCTAssertEqual(server.core.servingContentRequests.count, 0)
        sim.run(for: .seconds(1))
        replacement.read()
        XCTAssertEqual(replacement.chunks.map(\.requestID), [7])
        XCTAssertServingIdle(server)
    }

    // restart retains stalled Volume slots and byte reservations
    func testRestartRetainsServingVolumeReservations() {
        let sim = Simulation()
        let server = server(sim, slots: 2)
        for root in ["root-a", "root-b", "root-c", "root-d"] {
            server.volumes[root] = [ContentEntry(cid: root, data: Data())]
        }
        let first = (0..<2).map { ServingRawPeer(sim, to: server, index: $0 + 1) }
        server.stallsStorage = true
        first[0].send(.volumeRequest(requestID: 1, rootCID: "root-a"))
        first[1].send(.volumeRequest(requestID: 2, rootCID: "root-b"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        XCTAssertEqual(
            server.core.diagnostics.reservedServingVolumeBytes, IvyConfig.defaultMaxInFlightVolumeBytes)

        sim.stop(server)
        XCTAssertEqual(server.cancelledJobs.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        XCTAssertEqual(
            server.core.diagnostics.reservedServingVolumeBytes, IvyConfig.defaultMaxInFlightVolumeBytes)
        sim.start(server)
        sim.run(for: .milliseconds(50))
        let second = (0..<2).map { ServingRawPeer(sim, to: server, index: $0 + 3) }
        // Both retained slots are busy, so new requests wait for them.
        second[0].send(.volumeRequest(requestID: 3, rootCID: "root-c"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.volumeReads.count, 2)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)

        // A retained slot frees: the waiting request takes it.
        sim.releaseNextRead(server)
        XCTAssertEqual(server.volumeReads.count, 3)
        XCTAssertEqual(server.core.servingContentRequests.count, 2)
        second[1].send(.volumeRequest(requestID: 4, rootCID: "root-d"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)

        sim.releaseNextRead(server)
        XCTAssertEqual(server.volumeReads.count, 4)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        for (index, peer) in second.enumerated() {
            peer.read()
            XCTAssertEqual(peer.chunks.map(\.requestID), [UInt64(index + 3)])
        }
        XCTAssertServingIdle(server)
    }

    // closing a connection cancels its active content callback
    func testConnectionCloseCancelsContentCallback() {
        let sim = Simulation()
        let server = server(sim)
        let client = sim.node(requestTimeout: .seconds(3_600))
        sim.connect(client, server)
        server.stallsStorage = true
        let fetch = sim.fetchVolume("root", from: server, on: client)
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 1)
        let read = server.servingStalledJobs[0].id

        sim.stop(server)
        XCTAssertEqual(server.cancelledJobs, [read])
        sim.run(for: .seconds(1))
        XCTAssertEqual(sim.volume(fetch, on: client), .empty)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // transport close retires a session even if storage ignores cancellation
    func testConnectionCloseDoesNotWaitForStorage() {
        let sim = Simulation()
        let server = server(sim)
        let client = sim.node(requestTimeout: .seconds(3_600))
        sim.connect(client, server)
        server.stallsStorage = true
        let fetch = sim.fetchVolume("root", from: server, on: client)
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads.count, 1)

        sim.send(.command(.disconnect(server.peer)), to: client)
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.connectedPeers, [])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.cancelledJobs.count, 1)
        XCTAssertEqual(sim.volume(fetch, on: client), .empty)

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // MARK: - Deadlines and replies

    // A request answered in time leaves no deadline behind.
    func testServedRequestsLeaveNoDeadline() {
        let sim = Simulation()
        let server = server(sim, requestTimeout: .seconds(2))
        server.volumes["root"] = servingSmallVolume("root")
        server.bundles["root"] = ["root"]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        let deadlines = server.core.diagnostics.deadlines
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        peer.send(.volumeBundleRequest(requestID: 3, rootCID: "root"))
        peer.send(.volumeRequest(requestID: 4, rootCID: "absent"))
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.diagnostics.deadlines, deadlines)
        XCTAssertServingIdle(server)
        sim.run(for: .seconds(10))
        XCTAssertEqual(server.cancelledJobs, [])
        peer.read()
        XCTAssertEqual(peer.answeredRequestIDs.sorted(), [2, 3, 4])
    }
}
