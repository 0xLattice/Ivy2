import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// How a node spreads its own Volume requests: one peer asked at a time,
/// least loaded first, a per-peer in-flight limit that makes a fetch wait,
/// and peers that have been timing out asked last.
final class ClientVolumeSchedulingTests: XCTestCase {
    private func volume(_ root: String) -> [ContentEntry] {
        [ContentEntry(cid: root, data: Data("\(root) bytes".utf8))]
    }

    /// One client connected to several serving nodes.
    private func fixture(
        seed: UInt64 = 1,
        servers volumes: [[String]],
        requestTimeout: Duration = .seconds(10),
        maxOutstandingVolumeRequestsPerPeer: Int = 16
    ) -> (sim: Simulation, client: Simulation.Node, servers: [Simulation.Node]) {
        let sim = Simulation(seed: seed)
        let client = sim.fetchNode(
            requestTimeout: requestTimeout,
            maxOutstandingVolumeRequestsPerPeer: maxOutstandingVolumeRequestsPerPeer)
        let servers = volumes.map { roots -> Simulation.Node in
            let server = sim.node(requestTimeout: .seconds(10))
            for root in roots { server.volumes[root] = volume(root) }
            sim.connect(client, server)
            return server
        }
        return (sim, client, servers)
    }

    private func fetch(_ root: String) -> Request {
        .fetchVolume(
            rootCID: root,
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount))
    }

    /// A fetch asks one peer at a time, not every connected peer.
    func testAsksOnePeerAtATime() {
        let (sim, client, servers) = fixture(servers: [["root"], ["root"]])

        let response = sim.await(fetch("root"), on: client)?.volume

        XCTAssertEqual(response?.entries, ["root": Data("root bytes".utf8)])
        // Exactly one server read it, and the other was never asked.
        XCTAssertEqual(servers.map(\.volumeReadsStarted.count).reduce(0, +), 1)
        XCTAssertEqual(servers.filter { !$0.startedJobs.isEmpty }.count, 1)
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
    }

    /// A miss moves on to the next peer.
    func testMissRotatesToNextPeer() {
        var missedFirst = 0
        for seed in UInt64(1)...8 {
            let (sim, client, servers) = fixture(seed: seed, servers: [[], ["root"]])

            // Whichever is asked first, the fetch ends at the holder.
            let response = sim.await(fetch("root"), on: client)?.volume

            XCTAssertEqual(response?.entries, ["root": Data("root bytes".utf8)], "seed \(seed)")
            XCTAssertEqual(response?.servedBy, servers[1].peer, "seed \(seed)")
            XCTAssertEqual(client.core.freshProviderQueryCount, 0, "seed \(seed)")
            XCTAssertEqual(client.ledger.violations(of: servers[0].peer), 0)
            if !servers[0].startedJobs.isEmpty { missedFirst += 1 }
        }
        // Ties break at random: some run asked the peer without it first.
        XCTAssertGreaterThan(missedFirst, 0)
    }

    /// Requests in flight to one peer stay within the limit, and the rest wait.
    func testPerPeerLimitHolds() {
        let roots = (0..<5).map { "root-\($0)" }
        let (sim, client, servers) = fixture(servers: [roots], maxOutstandingVolumeRequestsPerPeer: 2)
        let server = servers[0]
        server.stallsStorage = true

        let fetches = roots.map { sim.request(fetch($0), on: client) }
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.startedJobs.count, 2)
        XCTAssertEqual(client.core.outstandingVolumeRequests[server.peer], 2)
        // The other three wait on the client rather than reaching the server.
        XCTAssertEqual(client.core.outstandingVolumeSlotWaiters.count, 3)
        XCTAssertEqual(server.core.serving.count, 2)
        for fetch in fetches { XCTAssertNil(sim.result(of: fetch, on: client)) }

        server.storageDelay = .milliseconds(200)
        sim.releaseStorage(server)
        var maximumOutstanding = 0
        var maximumServing = 0
        while fetches.contains(where: { sim.result(of: $0, on: client) == nil }), sim.now < .seconds(60) {
            sim.run(for: .milliseconds(5))
            maximumOutstanding = max(maximumOutstanding, client.core.outstandingVolumeRequests[server.peer] ?? 0)
            maximumServing = max(maximumServing, server.core.serving.count)
        }

        for (root, fetch) in zip(roots, fetches) {
            XCTAssertEqual(sim.result(of: fetch, on: client)?.volume?.entries, [root: Data("\(root) bytes".utf8)])
        }
        XCTAssertEqual(maximumOutstanding, 2)
        XCTAssertLessThanOrEqual(maximumServing, 2)
        XCTAssertNil(client.core.outstandingVolumeRequests[server.peer])
        XCTAssertTrue(client.core.outstandingVolumeSlotWaiters.isEmpty)
        assertHoldsNoVolumeBytes(client)
    }

    /// Requests spread across peers that both hold the content.
    func testRequestsSpreadAcrossPeers() {
        let roots = (0..<6).map { "root-\($0)" }
        let (sim, client, servers) = fixture(servers: [roots, roots], maxOutstandingVolumeRequestsPerPeer: 10)
        for server in servers { server.stallsStorage = true }

        let fetches = roots.map { sim.request(fetch($0), on: client) }
        // Least loaded first: three in flight to each peer, though either
        // peer's limit would take all six.
        XCTAssertEqual(client.core.outstandingVolumeRequests[servers[0].peer], 3)
        XCTAssertEqual(client.core.outstandingVolumeRequests[servers[1].peer], 3)
        XCTAssertTrue(client.core.outstandingVolumeSlotWaiters.isEmpty)

        for server in servers { sim.releaseStorage(server) }
        sim.run(until: { fetches.allSatisfy { sim.result(of: $0, on: client) != nil } })
        for (root, fetch) in zip(roots, fetches) {
            XCTAssertEqual(sim.result(of: fetch, on: client)?.volume?.entries, [root: Data("\(root) bytes".utf8)])
        }
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
    }

    /// Stopping releases requests waiting for a slot.
    func testStopReleasesWaiters() {
        let (sim, client, servers) = fixture(servers: [["a", "b"]], maxOutstandingVolumeRequestsPerPeer: 1)
        servers[0].stallsStorage = true

        let first = sim.request(fetch("a"), on: client)
        sim.run(until: { !servers[0].startedJobs.isEmpty })
        let waiting = sim.request(fetch("b"), on: client)
        XCTAssertEqual(client.core.outstandingVolumeSlotWaiters.count, 1)
        XCTAssertNil(sim.result(of: waiting, on: client))

        sim.stop(client)

        XCTAssertEqual(sim.result(of: waiting, on: client), .volume(.empty))
        XCTAssertEqual(sim.result(of: first, on: client), .volume(.empty))
        XCTAssertTrue(client.core.outstandingVolumeSlotWaiters.isEmpty)
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
        XCTAssertTrue(client.core.volumeFetches.isEmpty)
        // The server's read of the abandoned request holds nothing of the client's.
        sim.run(for: .seconds(1))
        sim.releaseStorage(servers[0])
        sim.run(for: .seconds(1))
        XCTAssertEqual(servers[0].startedJobs.count, 1)
        XCTAssertEqual(servers[0].core.diagnostics.servingSlotsHeld, 0)
    }

    /// A peer that let a request time out is tried after peers that answer.
    func testTimedOutPeerGoesLast() throws {
        let sim = Simulation()
        let client = sim.fetchNode(requestTimeout: .seconds(1))
        let silent = FetchRawPeer(sim, to: client, index: 0)

        // The only peer never replies: the fetch times out and records it.
        let started = sim.now
        let timedOut = sim.await(fetch("root"), on: client)?.volume
        XCTAssertEqual(timedOut?.entries, [:])
        XCTAssertEqual(sim.now - started, .seconds(1))
        XCTAssertNotNil(silent.takeVolumeRequest())
        XCTAssertEqual(client.core.volumeTimeoutStreaks[silent.peer], 1)
        XCTAssertEqual(client.ledger.violations(of: silent.peer), 0)

        // With a peer that answers connected, it is asked first: no timeout.
        // (Without the streak, a random tie would pick the silent peer about
        // half the time; eight fetches make that near certain to show.)
        let holder = sim.node()
        holder.volumes["root"] = volume("root")
        sim.connect(client, holder)
        for _ in 0..<8 {
            let began = sim.now
            let response = sim.await(fetch("root"), on: client)?.volume
            XCTAssertEqual(response?.servedBy, holder.peer)
            XCTAssertLessThan(sim.now - began, .milliseconds(800))
        }
        XCTAssertNil(silent.takeVolumeRequest())
        XCTAssertEqual(client.core.volumeTimeoutStreaks[silent.peer], 1)
        XCTAssertEqual(client.core.connectedPeers.count, 2)
    }

    /// A peer that starts a Volume and stalls is tried after peers that answer.
    func testStalledPeerGoesLast() throws {
        let sim = Simulation()
        let client = sim.fetchNode(requestTimeout: .seconds(5))
        let stalled = FetchRawPeer(sim, to: client, index: 0)

        // The only peer sends the first of two chunks and nothing more: the
        // fetch times out with the Volume begun, and that counts.
        let fetch = sim.request(self.fetch("root"), on: client)
        let requestID = try XCTUnwrap(stalled.takeVolumeRequest()).requestID
        stalled.send(.volumeChunk(
            requestID: requestID, rootCID: "root", index: 0, count: 2, totalEntries: 1, totalBytes: 2,
            payload: Data([1])))
        XCTAssertNotNil(client.core.pendingVolumeRequests[requestID]?.assemblies[stalled.peer])
        XCTAssertEqual(client.core.diagnostics.reservedVolumeBytes, 2)
        sim.run(until: { sim.result(of: fetch, on: client) != nil })
        XCTAssertEqual(sim.result(of: fetch, on: client)?.volume?.entries, [:])
        XCTAssertEqual(client.core.volumeTimeoutStreaks[stalled.peer], 1)
        assertHoldsNoVolumeBytes(client)

        // With a peer that answers connected, it is asked first: the stalled
        // peer is not asked, so it counts no further timeout.
        let holder = sim.node()
        holder.volumes["root"] = volume("root")
        sim.connect(client, holder)
        for _ in 0..<8 {
            XCTAssertEqual(sim.await(self.fetch("root"), on: client)?.volume?.servedBy, holder.peer)
        }
        XCTAssertNil(stalled.takeVolumeRequest())
        XCTAssertEqual(client.core.volumeTimeoutStreaks[stalled.peer], 1)
    }

    func testTimeoutStreakGrowsAndClearsWhenThePeerServes() throws {
        let sim = Simulation()
        let client = sim.fetchNode(requestTimeout: .seconds(1))
        let peer = FetchRawPeer(sim, to: client, index: 0)

        for streak in 1...2 {
            _ = sim.await(fetch("root"), on: client)
            XCTAssertNotNil(peer.takeVolumeRequest())
            XCTAssertEqual(client.core.volumeTimeoutStreaks[peer.peer], streak)
        }

        // A miss is an answer, not a timeout, but it is not a served Volume.
        let missed = sim.request(fetch("root"), on: client)
        peer.send(.contentUnavailable(requestID: try XCTUnwrap(peer.takeVolumeRequest()).requestID))
        XCTAssertEqual(sim.result(of: missed, on: client), .volume(.empty))
        XCTAssertEqual(client.core.volumeTimeoutStreaks[peer.peer], 2)

        let served = sim.request(fetch("root"), on: client)
        peer.sendVolume(requestID: try XCTUnwrap(peer.takeVolumeRequest()).requestID, root: "root")
        XCTAssertEqual(sim.result(of: served, on: client)?.volume?.servedBy, peer.peer)
        XCTAssertNil(client.core.volumeTimeoutStreaks[peer.peer])
    }

    func testTimeoutStreakIsDroppedWithTheSession() {
        let sim = Simulation()
        let client = sim.fetchNode(requestTimeout: .seconds(1))
        let peer = FetchRawPeer(sim, to: client, index: 0)
        _ = sim.await(fetch("root"), on: client)
        XCTAssertEqual(client.core.volumeTimeoutStreaks[peer.peer], 1)

        peer.close()

        XCTAssertTrue(client.core.volumeTimeoutStreaks.isEmpty)
    }

    /// Cancelling a fetch waiting for a slot withdraws it and leaks nothing.
    func testCancelWhileWaitingForSlot() {
        let (sim, client, servers) = fixture(servers: [["a", "b"]], maxOutstandingVolumeRequestsPerPeer: 1)
        let server = servers[0]
        server.stallsStorage = true

        let first = sim.request(fetch("a"), on: client)
        sim.run(until: { !server.startedJobs.isEmpty })
        let waiting = sim.request(fetch("b"), on: client)
        XCTAssertEqual(client.core.outstandingVolumeSlotWaiters.count, 1)

        sim.cancel(waiting, on: client)
        XCTAssertEqual(sim.result(of: waiting, on: client), .volume(.empty))
        XCTAssertTrue(client.core.outstandingVolumeSlotWaiters.isEmpty)
        XCTAssertEqual(client.core.outstandingVolumeRequests[server.peer], 1)

        sim.releaseStorage(server)
        sim.run(until: { sim.result(of: first, on: client) != nil })
        XCTAssertEqual(sim.result(of: first, on: client)?.volume?.entries, ["a": Data("a bytes".utf8)])
        sim.run(for: .seconds(1))
        XCTAssertNil(client.core.outstandingVolumeRequests[server.peer])
        // The withdrawn fetch never reached the server.
        XCTAssertEqual(server.volumeReadsStarted, ["a"])
        XCTAssertTrue(client.core.volumeFetches.isEmpty)
    }

    /// Cancelling a fetch mid-request releases its slot.
    func testCancelMidRequestReleasesSlot() {
        let (sim, client, servers) = fixture(servers: [["a"]])
        let server = servers[0]
        server.stallsStorage = true

        let fetch = sim.request(self.fetch("a"), on: client)
        sim.run(until: { !server.startedJobs.isEmpty })
        XCTAssertEqual(client.core.outstandingVolumeRequests[server.peer], 1)

        sim.cancel(fetch, on: client)

        XCTAssertEqual(sim.result(of: fetch, on: client), .volume(.empty))
        XCTAssertNil(client.core.outstandingVolumeRequests[server.peer])
        XCTAssertTrue(client.core.pendingVolumeRequests.isEmpty)
        // The Volume arrives for nobody.
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        assertHoldsNoVolumeBytes(client)
        XCTAssertEqual(client.ledger.violations(of: server.peer), 0)
        XCTAssertEqual(client.core.connectedPeers, [server.peer])
    }

    /// The freed slot goes to a fetch that was waiting for it.
    func testWaitingFetchTakesTheSlotAMissFrees() throws {
        let sim = Simulation()
        let client = sim.fetchNode(maxOutstandingVolumeRequestsPerPeer: 1)
        let peer = FetchRawPeer(sim, to: client, index: 0)

        let first = sim.request(fetch("a"), on: client)
        let firstID = try XCTUnwrap(peer.takeVolumeRequest()).requestID
        let second = sim.request(fetch("b"), on: client)
        XCTAssertNil(peer.takeVolumeRequest())
        XCTAssertEqual(client.core.outstandingVolumeSlotWaiters.count, 1)

        peer.send(.contentUnavailable(requestID: firstID))
        XCTAssertEqual(sim.result(of: first, on: client), .volume(.empty))
        let next = try XCTUnwrap(peer.takeVolumeRequest())
        XCTAssertEqual(next.rootCID, "b")
        XCTAssertTrue(client.core.outstandingVolumeSlotWaiters.isEmpty)
        XCTAssertEqual(client.core.outstandingVolumeRequests[peer.peer], 1)

        peer.sendVolume(requestID: next.requestID, root: "b")
        XCTAssertEqual(sim.result(of: second, on: client)?.volume?.rootCID, "b")
        XCTAssertTrue(client.core.outstandingVolumeRequests.isEmpty)
    }

    /// The per-peer limit is validated.
    func testLimitValidated() {
        let key = Simulation().signingKey(index: 0)
        XCTAssertThrowsError(
            try IvyConfig(signingKey: key, listenPort: 0, maxOutstandingVolumeRequestsPerPeer: 0).validate())
        XCTAssertEqual(IvyConfig(signingKey: key, listenPort: 0).maxOutstandingVolumeRequestsPerPeer, 16)
    }
}
