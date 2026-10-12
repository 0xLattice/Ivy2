import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Volume fetches between whole nodes, and what a requester sees of the
/// node serving it: authorization, stalls, closes and replaced sessions.
final class ContentExchangeEndToEndTests: XCTestCase {
    private func pair(
        serverTimeout: Duration = .seconds(15),
        mode: IvyMode = .overlay,
        privateContentExchangeEnabled: Bool = false
    ) -> (sim: Simulation, server: Simulation.Node, client: Simulation.Node, serverPeer: AuthenticatedPeer) {
        let sim = Simulation()
        let server = sim.node(
            mode: mode, requestTimeout: serverTimeout, privateContentExchangeEnabled: privateContentExchangeEnabled)
        let client = sim.node(mode: mode, privateContentExchangeEnabled: privateContentExchangeEnabled)
        sim.connect(client, server)
        return (sim, server, client, sim.session(client, to: server))
    }

    private let anyBytes = MessageLimits.maxVolumeArchiveBytes
    private let anyEntries = Int(MessageLimits.maxVolumeEntryCount)

    private func fetchFrom(_ peer: AuthenticatedPeer, _ root: String) -> Request {
        .fetchVolumeFrom(peer, rootCID: root, maximumArchiveBytes: anyBytes, maximumEntries: anyEntries)
    }

    /// The IDs of the requests the node answered with a chunk, and those it refused.
    private func replies(_ requester: FetchRawPeer) -> (chunks: [UInt64], unavailable: [UInt64]) {
        var chunks: [UInt64] = []
        var unavailable: [UInt64] = []
        for message in requester.takeMessages() {
            switch message {
            case .volumeChunk(let requestID, _, _, _, _, _, _): chunks.append(requestID)
            case .contentUnavailable(let requestID): unavailable.append(requestID)
            default: break
            }
        }
        return (chunks, unavailable)
    }

    // MARK: - Whole nodes

    /// A targeted Volume crosses an authenticated session.
    func testTargetedVolume() {
        let (sim, server, client, serverPeer) = pair()
        let root = "opaque-root"
        let child = "opaque-child"
        server.volumes[root] = [
            ContentEntry(cid: root, data: Data("root bytes".utf8)),
            ContentEntry(cid: child, data: Data("child bytes".utf8)),
        ]

        let response = sim.await(fetchFrom(serverPeer, root), on: client)?.volume
        XCTAssertEqual(response?.entries, [root: Data("root bytes".utf8), child: Data("child bytes".utf8)])
        XCTAssertEqual(response?.servedBy, server.peer)

        sim.send(.command(.reportDeficientContent(rootCID: root, servedBy: server.peer)), to: client)
        XCTAssertEqual(client.core.peerConnectionCount, 1)
        let sync = Data("next range".utf8)
        XCTAssertEqual(
            sim.await(.send(to: server.peer, topic: "sync.request", payload: sync), on: client)?.sent,
            .enqueued(endpoint: server.peer, route: .direct))
        sim.run(until: { !server.received.isEmpty })
        XCTAssertEqual(server.received.first?.message, PeerMessage(topic: "sync.request", payload: sync))
        XCTAssertEqual(server.received.first?.peer.id, client.peer)
        XCTAssertTrue(client.disconnected.isEmpty)
        assertHoldsNoVolumeBytes(client)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }

    /// A fetch with no provider record reaches a connected peer that holds
    /// the Volume.
    func testFetchIsServedByAConnectedPeer() {
        let (sim, server, client, _) = pair()
        server.volumes["root"] = [
            ContentEntry(cid: "root", data: Data("root".utf8)),
            ContentEntry(cid: "leaf", data: Data("leaf".utf8)),
        ]

        let response = sim.await(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: anyBytes, maximumEntries: anyEntries),
            on: client)

        XCTAssertEqual(response, .volume(AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": Data("root".utf8), "leaf": Data("leaf".utf8)],
            servedBy: server.peer)))
        // One request, one read on the server.
        XCTAssertEqual(server.volumeReadsStarted, ["root"])
        assertHoldsNoVolumeBytes(client)
        XCTAssertEqual(client.core.diagnostics.servingSlotsHeld, 0)
    }

    /// A peer with no serving credit is served every request it makes.
    func testUnknownPeerIsServedPastRequestCapacity() {
        let (sim, server, client, serverPeer) = pair()
        server.volumes["root"] = [ContentEntry(cid: "root", data: Data("root".utf8))]
        XCTAssertEqual(server.ledger.servingPriority(for: client.peer), 0)

        for _ in 0..<20 {
            XCTAssertEqual(
                sim.await(fetchFrom(serverPeer, "root"), on: client)?.volume,
                AttributedVolumeResponse(
                    rootCID: "root", entries: ["root": Data("root".utf8)], servedBy: server.peer))
        }
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }

    /// Private-network nodes exchange content only when both opt in, and
    /// only between sessions: nothing is looked up.
    func testPrivateNetworkContentExchange() {
        let (sim, server, client, serverPeer) = pair(mode: .privateNetwork, privateContentExchangeEnabled: true)
        server.volumes["private-root"] = [
            ContentEntry(cid: "private-root", data: Data("root bytes".utf8)),
            ContentEntry(cid: "private-child", data: Data("child bytes".utf8)),
        ]

        let fetched = sim.await(fetchFrom(serverPeer, "private-root"), on: client)?.volume

        XCTAssertEqual(fetched?.entries, [
            "private-root": Data("root bytes".utf8),
            "private-child": Data("child bytes".utf8),
        ])
        XCTAssertTrue(client.core.knownPeerEndpoints.isEmpty)
        XCTAssertEqual(client.core.freshProviderQueryCount, 0)
    }

    /// Stopping the serving node cancels its active content callback.
    func testConnectionCloseCancelsContentCallback() {
        let (sim, server, client, serverPeer) = pair()
        server.stallsStorage = true

        let request = sim.request(fetchFrom(serverPeer, "root"), on: client)
        sim.run(until: { !server.startedJobs.isEmpty })
        XCTAssertNil(sim.result(of: request, on: client))

        sim.stop(server)
        XCTAssertEqual(server.cancelledJobs, server.startedJobs.map(\.id))
        sim.run(until: { sim.result(of: request, on: client) != nil })
        XCTAssertEqual(sim.result(of: request, on: client), .volume(.empty))
        XCTAssertLessThan(sim.now, .seconds(1))
        XCTAssertTrue(client.core.pendingVolumeRequests.isEmpty)
    }

    /// A transport close retires a session even if storage ignores cancellation.
    func testConnectionCloseDoesNotWaitForStorage() {
        let (sim, server, client, serverPeer) = pair()
        server.stallsStorage = true

        let request = sim.request(fetchFrom(serverPeer, "root"), on: client)
        sim.run(until: { !server.startedJobs.isEmpty })

        sim.send(.command(.disconnect(server.peer)), to: client)
        XCTAssertEqual(sim.result(of: request, on: client), .volume(.empty))
        sim.run(until: { server.core.peerConnectionCount == 0 })
        XCTAssertEqual(server.core.peerConnectionCount, 0)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.cancelledJobs, server.startedJobs.map(\.id))

        sim.releaseStorage(server)
        sim.settleDue()
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(server.core.diagnostics.jobsOutstanding, 0)
        XCTAssertEqual(server.startedJobs.count, 1)
    }

    /// A stalled authenticated Volume writer releases its reservation at the deadline.
    func testStalledVolumeWriterTimesOut() throws {
        let (sim, server, client, serverPeer) = pair(serverTimeout: .seconds(1))
        let entries = [ContentEntry(
            cid: "root", data: Data(repeating: 0xa5, count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1))]
        // While it is sent, a Volume holds its encoded size, not the worst case.
        let archiveBytes = try XCTUnwrap(VolumeArchive.encode(entries: entries, rootCID: "root")).data.count
        server.volumes["root"] = entries
        // The client stops taking the server's bytes: its application holds a delivery.
        client.holdsDeliveries = true
        _ = sim.await(.send(to: client.peer, topic: "hold", payload: Data([1])), on: server)
        sim.run(until: { !client.heldDeliveries.isEmpty })
        // Lets the server hear that the held record itself was taken.
        sim.run(for: .milliseconds(100))

        let fetch = sim.request(
            .fetchVolumeFrom(
                serverPeer,
                rootCID: "root",
                maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
                maximumEntries: Int(MessageLimits.maxVolumeEntryCount)),
            on: client)
        XCTAssertTrue(sim.run(
            until: { server.core.diagnostics.reservedServingVolumeBytes == archiveBytes }, timeout: .seconds(1)))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        let stalledAt = sim.now
        XCTAssertTrue(sim.run(
            until: { server.core.diagnostics.reservedServingVolumeBytes == 0 }, timeout: .seconds(2)))
        XCTAssertLessThanOrEqual(sim.now - stalledAt, .seconds(1))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)

        sim.run(until: { sim.result(of: fetch, on: client) != nil })
        XCTAssertEqual(sim.result(of: fetch, on: client), .volume(.empty))
        assertHoldsNoVolumeBytes(client)
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
    }

    // MARK: - The serving node, seen by a requester played by hand

    /// Private content exchange requires explicit opt-in.
    func testPrivateContentExchangeRequiresOptIn() {
        let sim = Simulation()
        let disabled = sim.node(mode: .privateNetwork)
        let enabled = sim.node(mode: .privateNetwork, privateContentExchangeEnabled: true)
        enabled.authorize = { _, _ in false }

        let ignored = FetchRawPeer(sim, to: disabled, index: 0)
        ignored.send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.settleDue()
        XCTAssertTrue(disabled.startedJobs.isEmpty)
        XCTAssertTrue(ignored.takeMessages().isEmpty)
        XCTAssertEqual(disabled.core.connectedPeers, [ignored.peer])

        let answered = FetchRawPeer(sim, to: enabled, index: 1)
        answered.send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.settleDue()
        XCTAssertEqual(enabled.authorizationsStarted, 1)
        XCTAssertTrue(enabled.volumeReadsStarted.isEmpty)
        XCTAssertEqual(replies(answered).unavailable, [2])
    }

    /// Tags 26 and 50 carried content selections and are retired: a record
    /// with one is ignored like any message this version does not know.
    func testRetiredContentSelectionRecordsAreIgnored() throws {
        let sim = Simulation()
        let server = sim.node()
        server.volumes["root"] = [ContentEntry(cid: "root", data: Data("root".utf8))]
        let requester = FetchRawPeer(sim, to: server, index: 0)

        // A 15.x `contentRequest` and `contentResponse`, as they were framed.
        for hex in ["1a0000000000000003000172000200016100026263", "3200000000000000030000"] {
            requester.sendPayload(try XCTUnwrap(Data(hexString: hex)))
        }
        sim.settleDue()

        XCTAssertTrue(server.startedJobs.isEmpty)
        XCTAssertTrue(requester.takeMessages().isEmpty)
        XCTAssertEqual(server.core.connectedPeers, [requester.peer])
        XCTAssertTrue(server.disconnected.isEmpty)
        XCTAssertEqual(server.ledger.violations(of: requester.peer), 0)

        // The session carries on with the records that follow.
        requester.send(.volumeRequest(requestID: 3, rootCID: "root"))
        sim.settleDue()
        XCTAssertEqual(replies(requester).chunks, [3])
    }

    /// A disconnected peer retains its serving slot until storage exits.
    func testDisconnectedPeerRetainsServingSlot() {
        let sim = Simulation()
        let server = sim.node(maxConcurrentContentRequests: 8)
        server.volumes["root"] = [ContentEntry(cid: "root", data: Data("root".utf8))]
        server.stallsStorage = true
        let requester = FetchRawPeer(sim, to: server, index: 0)

        requester.send(.volumeRequest(requestID: 7, rootCID: "root"))
        XCTAssertEqual(server.startedJobs.count, 1)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)

        requester.close()
        XCTAssertTrue(server.core.connectedPeers.isEmpty)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertTrue(requester.handshake())
        requester.send(.volumeRequest(requestID: 7, rootCID: "root"))
        XCTAssertEqual(server.startedJobs.count, 2)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 2)

        // The old session's storage call exits: only its slot frees.
        sim.send(.jobFinished(server.startedJobs[0].id, .authorized(true)), to: server)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.startedJobs.count, 2)

        sim.send(.jobFinished(server.startedJobs[1].id, .authorized(true)), to: server)
        XCTAssertEqual(server.startedJobs.count, 3)
        sim.send(
            .jobFinished(server.startedJobs[2].id, .entries([ContentEntry(cid: "root", data: Data("root".utf8))])),
            to: server)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(replies(requester).chunks, [7])
    }

    /// A replaced session cannot deliver a stale reply.
    func testStaleSessionReply() {
        let sim = Simulation()
        let server = sim.node()
        server.volumes["root"] = [ContentEntry(cid: "root", data: Data("root".utf8))]
        server.stallsStorage = true
        let requester = FetchRawPeer(sim, to: server, index: 0)

        requester.send(.volumeRequest(requestID: 7, rootCID: "root"))
        XCTAssertEqual(server.startedJobs.count, 1)
        let oldConnection = requester.connection

        requester.replaceSession()
        XCTAssertTrue(sim.nodeClosedRaw(oldConnection))
        requester.send(.volumeRequest(requestID: 7, rootCID: "root"))
        XCTAssertEqual(server.startedJobs.count, 2)
        // The old request's job was cancelled with its session and still holds its slot.
        XCTAssertEqual(server.cancelledJobs, [server.startedJobs[0].id])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 2)

        sim.releaseStorage(server)
        sim.run(for: .milliseconds(100))

        // One reply, on the session that asked last; nothing more on the old connection.
        XCTAssertEqual(replies(requester).chunks, [7])
        XCTAssertTrue(sim.takeRawOutput(oldConnection).isEmpty)
        XCTAssertEqual(server.volumeReadsStarted, ["root"])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
    }
}
