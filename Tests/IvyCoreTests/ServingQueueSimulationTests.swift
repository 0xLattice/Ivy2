import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// One server and several clients, each its own identity. Reads on the
/// server are held until released, so a test decides when a slot frees.
private struct ServingFixture {
    let sim = Simulation()
    let server: Simulation.Node
    let clients: [Simulation.Node]

    init(
        clients count: Int,
        maxConcurrentContentRequests: Int = 64,
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes
    ) {
        // Deadlines are out of the way here: they have their own tests.
        server = sim.node(
            requestTimeout: .seconds(3_600),
            maxConcurrentContentRequests: maxConcurrentContentRequests,
            maxInFlightVolumeBytes: maxInFlightVolumeBytes)
        // Clients send freely so these tests observe the server's queue.
        var clients: [Simulation.Node] = []
        for _ in 0..<count {
            let client = sim.node(
                requestTimeout: .seconds(3_600), maxOutstandingVolumeRequestsPerPeer: 1_000)
            sim.connect(client, server)
            clients.append(client)
        }
        self.clients = clients
        server.stallsStorage = true
    }

    func fetch(_ client: Int, _ root: String) -> RequestID {
        server.volumes[root] = [ContentEntry(cid: root, data: Data("\(root) bytes".utf8))]
        let request = sim.fetchVolume(root, from: server, on: clients[client])
        sim.runHoldingReads(server)
        return request
    }

    func served(_ request: RequestID, _ client: Int, _ root: String) -> Bool {
        sim.volume(request, on: clients[client])?.entries == [root: Data("\(root) bytes".utf8)]
    }

    var waiting: Int { server.core.diagnostics.servingRequestsWaiting }

    /// Stops holding reads and runs until every client has its answers.
    func open() {
        sim.releaseStorage(server)
        sim.run(for: .seconds(5))
    }
}

final class ServingQueueSimulationTests: XCTestCase {
    // without pressure, requests are served at once and never queue
    func testNoPressureNoQueue() {
        let fixture = ServingFixture(clients: 2)
        fixture.server.stallsStorage = false
        let fetches = (0..<4).map { fixture.fetch($0 % 2, "root-\($0)") }
        fixture.open()
        for (index, fetch) in fetches.enumerated() {
            XCTAssertTrue(fixture.served(fetch, index % 2, "root-\(index)"))
        }
        // No request ever became a ticket.
        XCTAssertEqual(fixture.server.core.nextServingTicketArrival, 0)
        XCTAssertEqual(fixture.server.core.servingVirtualTime, 0)
        XCTAssertServingIdle(fixture.server)
    }

    // one peer alone can occupy every slot, and its next request waits
    func testOnePeerTakesEverySlot() {
        let fixture = ServingFixture(clients: 1, maxConcurrentContentRequests: 4)
        let active = (0..<4).map { fixture.fetch(0, "active-\($0)") }
        XCTAssertEqual(fixture.server.core.servingContentRequests.count, 4)
        XCTAssertEqual(fixture.waiting, 0)
        let fifth = fixture.fetch(0, "fifth")
        XCTAssertEqual(fixture.waiting, 1)
        XCTAssertEqual(fixture.server.core.diagnostics.servingSlotsHeld, 4)
        fixture.open()
        for (index, fetch) in active.enumerated() {
            XCTAssertTrue(fixture.served(fetch, 0, "active-\(index)"))
        }
        XCTAssertTrue(fixture.served(fifth, 0, "fifth"))
        XCTAssertServingIdle(fixture.server)
    }

    // with every slot busy, a peer's 200 requests all wait and all are served: none is refused
    func testOverflowWaitsNeverRefused() {
        let fixture = ServingFixture(clients: 1, maxConcurrentContentRequests: 2)
        let fetches = (0..<200).map { index -> RequestID in
            fixture.server.volumes["root-\(index)"] =
                [ContentEntry(cid: "root-\(index)", data: Data("root-\(index) bytes".utf8))]
            return fixture.sim.fetchVolume("root-\(index)", from: fixture.server, on: fixture.clients[0])
        }
        fixture.sim.runHoldingReads(fixture.server)
        XCTAssertEqual(fixture.server.volumeReads.count, 2)
        XCTAssertEqual(fixture.waiting, 198)
        fixture.open()
        for (index, fetch) in fetches.enumerated() {
            XCTAssertTrue(fixture.served(fetch, 0, "root-\(index)"), "root-\(index)")
        }
        XCTAssertEqual(fixture.server.volumeReads, (0..<200).map { "root-\($0)" })
        XCTAssertServingIdle(fixture.server)
    }

    // under pressure, the peer that served us the most verified content goes first
    func testHelpfulPeerFirst() {
        let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
        // Client 2 has served this node verified content; client 1 has not.
        fixture.server.ledger.setServingPriority(10_000, for: fixture.clients[2].peer)
        let holder = fixture.fetch(0, "holder")
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        let stranger = fixture.fetch(1, "stranger")
        XCTAssertEqual(fixture.waiting, 1)
        let helpful = fixture.fetch(2, "helpful")
        XCTAssertEqual(fixture.waiting, 2)

        fixture.sim.releaseNextRead(fixture.server)
        XCTAssertEqual(fixture.server.volumeReads, ["holder", "helpful"])
        fixture.sim.releaseNextRead(fixture.server)
        XCTAssertEqual(fixture.server.volumeReads, ["holder", "helpful", "stranger"])
        fixture.open()
        XCTAssertTrue(fixture.served(holder, 0, "holder"))
        XCTAssertTrue(fixture.served(helpful, 2, "helpful"))
        XCTAssertTrue(fixture.served(stranger, 1, "stranger"))
        XCTAssertServingIdle(fixture.server)
    }

    // among equally helpful peers, the oldest waiter goes first
    func testEqualPriorityIsFIFO() {
        let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
        let holder = fixture.fetch(0, "holder")
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        let older = fixture.fetch(1, "older")
        XCTAssertEqual(fixture.waiting, 1)
        let newer = fixture.fetch(2, "newer")
        XCTAssertEqual(fixture.waiting, 2)
        fixture.sim.releaseNextRead(fixture.server)
        XCTAssertEqual(fixture.server.volumeReads, ["holder", "older"])
        fixture.open()
        XCTAssertTrue(fixture.served(holder, 0, "holder"))
        XCTAssertTrue(fixture.served(older, 1, "older"))
        XCTAssertTrue(fixture.served(newer, 2, "newer"))
        XCTAssertEqual(fixture.server.volumeReads, ["holder", "older", "newer"])
    }

    // The tie goes to the older request whichever peer sorts first.
    func testEqualPriorityIsFIFOWhicheverPeerAskedFirst() {
        for order in [[1, 2], [2, 1]] {
            let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
            _ = fixture.fetch(0, "holder")
            _ = fixture.fetch(order[0], "older")
            _ = fixture.fetch(order[1], "newer")
            XCTAssertEqual(fixture.waiting, 2)
            fixture.open()
            XCTAssertEqual(fixture.server.volumeReads, ["holder", "older", "newer"])
        }
    }

    // a peer's waiting requests are withdrawn when it disconnects
    func testWaiterWithdrawnOnDisconnect() {
        let fixture = ServingFixture(clients: 2, maxConcurrentContentRequests: 1)
        let holder = fixture.fetch(0, "holder")
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        let leaver = (0..<20).map { fixture.fetch(1, "leaver-\($0)") }
        XCTAssertEqual(fixture.waiting, 20)
        fixture.sim.stop(fixture.clients[1])
        fixture.sim.runHoldingReads(fixture.server)
        XCTAssertEqual(fixture.waiting, 0)
        XCTAssertTrue(fixture.server.core.waitingServingPeers.isEmpty)
        fixture.open()
        XCTAssertTrue(fixture.served(holder, 0, "holder"))
        for fetch in leaver {
            XCTAssertEqual(fixture.sim.volume(fetch, on: fixture.clients[1]), .empty)
        }
        XCTAssertEqual(fixture.server.volumeAuthorizations, ["holder"])
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        XCTAssertServingIdle(fixture.server)
    }

    // stopping the server refuses every waiting request
    func testStopRefusesWaiters() {
        let fixture = ServingFixture(clients: 2, maxConcurrentContentRequests: 1)
        _ = fixture.fetch(0, "holder")
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        let waiter = fixture.fetch(1, "waiter")
        XCTAssertEqual(fixture.waiting, 1)
        fixture.sim.stop(fixture.server)
        XCTAssertEqual(fixture.waiting, 0)
        XCTAssertTrue(fixture.server.core.waitingServingPeers.isEmpty)
        fixture.open()
        XCTAssertEqual(fixture.sim.volume(waiter, on: fixture.clients[1]), .empty)
        // The waiting request never reached storage.
        XCTAssertEqual(fixture.server.volumeAuthorizations, ["holder"])
        XCTAssertServingIdle(fixture.server)
    }

    // Volume reads waiting for capacity go first come, first served, whatever the credit
    func testReadQueueIsFIFO() {
        // Slots to spare; room for exactly one worst-case read at a time.
        let fixture = ServingFixture(clients: 3, maxInFlightVolumeBytes: MessageLimits.maxVolumeArchiveBytes)
        fixture.server.ledger.setServingPriority(1_000_000, for: fixture.clients[2].peer)
        let holder = fixture.fetch(0, "holder")
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        let stranger = fixture.fetch(1, "stranger")
        XCTAssertEqual(fixture.server.core.diagnostics.servingVolumeReadsWaiting, 1)
        let helpful = fixture.fetch(2, "helpful")
        XCTAssertEqual(fixture.server.core.diagnostics.servingVolumeReadsWaiting, 2)
        XCTAssertEqual(fixture.waiting, 0)
        XCTAssertEqual(fixture.server.core.diagnostics.servingSlotsHeld, 3)
        fixture.open()
        XCTAssertTrue(fixture.served(holder, 0, "holder"))
        XCTAssertTrue(fixture.served(stranger, 1, "stranger"))
        XCTAssertTrue(fixture.served(helpful, 2, "helpful"))
        XCTAssertEqual(fixture.server.volumeReads, ["holder", "stranger", "helpful"])
        XCTAssertServingIdle(fixture.server)
    }

    // under sustained pressure a newcomer with no credit keeps being served, at its weighted share
    func testNewcomerSyncsUnderSustainedPressure() {
        let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
        // 1 MiB of credit: weight 1 + log2(1 + 1024) ≈ 11 against the newcomer's 1.
        fixture.server.ledger.setServingPriority(1_048_576, for: fixture.clients[1].peer)
        _ = fixture.fetch(0, "holder")
        XCTAssertEqual(fixture.server.volumeReads, ["holder"])
        var fetches: [(RequestID, Int)] = []
        for index in 0..<30 {
            fetches.append((fixture.fetch(1, "credited-\(index)"), 1))
            XCTAssertEqual(fixture.waiting, index + 1)
        }
        for index in 0..<3 {
            fetches.append((fixture.fetch(2, "newcomer-\(index)"), 2))
            XCTAssertEqual(fixture.waiting, 31 + index)
        }
        // Grant one slot at a time and record who was served.
        for grant in 1...33 {
            fixture.sim.releaseNextRead(fixture.server)
            XCTAssertEqual(fixture.server.volumeReads.count, grant + 1)
        }
        fixture.open()
        for (fetch, client) in fetches {
            XCTAssertFalse(fixture.sim.volume(fetch, on: fixture.clients[client])?.entries.isEmpty ?? true)
        }

        let order = Array(fixture.server.volumeReads.dropFirst())
        let newcomerPositions = order.indices.filter { order[$0].hasPrefix("newcomer") }
        XCTAssertEqual(newcomerPositions.count, 3)
        // The newcomer is reached within one stride of the credited peer
        // (about 11 grants) and then about every 12.
        XCTAssertLessThanOrEqual(newcomerPositions.first ?? .max, 14)
        for (earlier, later) in zip(newcomerPositions, newcomerPositions.dropFirst()) {
            XCTAssertTrue((8...14).contains(later - earlier - 1), "\(newcomerPositions)")
        }
        XCTAssertServingIdle(fixture.server)
    }

    // credited peers re-requesting one at a time cannot starve a newcomer
    func testSequentialCreditedPeersCannotStarveNewcomer() {
        let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
        for credited in [0, 1] {
            fixture.server.ledger.setServingPriority(1_048_576, for: fixture.clients[credited].peer)
        }
        // Each credited peer syncs sequentially: the next request only after a reply.
        var current = [0, 1].map { fixture.fetch($0, "c\($0)-0") }
        var next = [1, 1]
        XCTAssertEqual(fixture.server.volumeReads.count, 1)
        XCTAssertEqual(fixture.waiting, 1)
        let newcomer = fixture.fetch(2, "newcomer")
        XCTAssertEqual(fixture.waiting, 2)

        var grants = 0
        var lastVirtualTime = fixture.server.core.servingVirtualTime
        while !fixture.server.volumeReads.contains("newcomer"), grants < 40 {
            let before = fixture.server.volumeReads.count
            fixture.sim.releaseNextRead(fixture.server)
            for credited in [0, 1] where fixture.sim.volume(current[credited], on: fixture.clients[credited]) != nil {
                current[credited] = fixture.fetch(credited, "c\(credited)-\(next[credited])")
                next[credited] += 1
            }
            XCTAssertGreaterThan(fixture.server.volumeReads.count, before)
            XCTAssertGreaterThanOrEqual(fixture.server.core.servingVirtualTime, lastVirtualTime)
            lastVirtualTime = fixture.server.core.servingVirtualTime
            grants += 1
        }
        // Two credited peers at weight ~11 each against 1: the newcomer is
        // reached within about two of their strides.
        XCTAssertTrue(fixture.server.volumeReads.contains("newcomer"))
        XCTAssertLessThanOrEqual(grants, 30)
        fixture.open()
        XCTAssertTrue(fixture.served(newcomer, 2, "newcomer"))
    }

    // the serving slot total must be positive
    func testConfigurationValidation() throws {
        let key = Simulation().signingKey(index: 0)
        func config(concurrent: Int) -> IvyConfig {
            IvyConfig(signingKey: key, listenPort: 0, maxConcurrentContentRequests: concurrent)
        }
        XCTAssertThrowsError(try config(concurrent: 0).validate())
        XCTAssertNoThrow(try config(concurrent: 1).validate())
    }

    // a deep queue from one peer is admitted and served in arrival order
    func testDeepQueueIsServedInOrder() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600), maxConcurrentContentRequests: 1)
        server.volumes["root"] = [ContentEntry(cid: "root", data: Data("bytes".utf8))]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        // Request 1 takes the only slot and 5,000 more wait behind it.
        for id in 1...5_001 { peer.send(.volumeRequest(requestID: UInt64(id), rootCID: "root")) }
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 5_000)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.core.waitingServingPeers.count, 1)

        sim.releaseStorage(server)
        sim.run(until: { server.core.serving.isEmpty }, timeout: .seconds(600))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertEqual(peer.chunks.map(\.requestID), (1...5_001).map(UInt64.init))
        XCTAssertServingIdle(server)
        XCTAssertTrue(server.core.servingTickets.isEmpty)
    }

    // MARK: - Beyond the reference suite

    func testServingWeightIsOnePlusLogOfCreditInKiB() {
        let sim = Simulation()
        let server = sim.node()
        let peers = (0..<5).map { _ in sim.node(start: false).peer }
        let credits: [Double] = [0, 1_024, 1_048_576, 1_073_741_824, -500]
        for (peer, credit) in zip(peers, credits) { server.ledger.setServingPriority(credit, for: peer) }
        let weights = peers.map { server.core.servingWeight(of: $0) }
        XCTAssertEqual(weights[0], 1)
        XCTAssertEqual(weights[1], 2)
        XCTAssertEqual(weights[2], 1 + log2(1_025), accuracy: 1e-12)
        XCTAssertEqual(weights[2], 11, accuracy: 0.01)
        XCTAssertEqual(weights[3], 21, accuracy: 0.01)
        // Negative credit is no credit, not a share below a stranger's.
        XCTAssertEqual(weights[4], 1)
        // A peer the ledger has never heard of.
        XCTAssertEqual(server.core.servingWeight(of: sim.node(start: false).peer), 1)
    }

    // A duplicate (same peer, session, request ID) is refused while the
    // first is waiting, while it is being served, and not afterwards.
    func testDuplicateRequestIsRefusedWithContentUnavailable() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600), maxConcurrentContentRequests: 1)
        server.volumes["root"] = servingSmallVolume("root")
        server.content["root"] = Data("content".utf8)
        server.bundles["root"] = ["root"]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        let other = ServingRawPeer(sim, to: server, index: 2)
        server.stallsStorage = true

        peer.send(.volumeRequest(requestID: 1, rootCID: "root"))
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)

        // The same ID again, whatever kind of request reuses it.
        peer.send(.volumeRequest(requestID: 1, rootCID: "root"))
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        peer.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        peer.send(.contentRequest(requestID: 2, rootCID: "root", cids: []))
        // Another peer's request with the same ID is its own request.
        other.send(.volumeRequest(requestID: 1, rootCID: "root"))
        sim.runHoldingReads(server)
        peer.read()
        other.read()
        XCTAssertEqual(peer.unavailable, [1, 1, 1, 2, 2])
        XCTAssertEqual(other.unavailable, [])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 2)

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        other.read()
        // The refusals did not disturb the requests they duplicated.
        XCTAssertEqual(peer.unavailable, [1, 1, 1, 2, 2])
        XCTAssertNotNil(peer.archive(requestID: 1, rootCID: "root"))
        XCTAssertNotNil(peer.archive(requestID: 2, rootCID: "root"))
        XCTAssertNotNil(other.archive(requestID: 1, rootCID: "root"))
        XCTAssertServingIdle(server)

        // Once answered, the ID is free again.
        peer.send(.contentRequest(requestID: 1, rootCID: "root", cids: []))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.contentResponses.map(\.requestID), [1])
        XCTAssertEqual(peer.unavailable, [1, 1, 1, 2, 2])
        XCTAssertServingIdle(server)
    }

    // A peer that keeps waiting keeps its pass: asking again while it waits
    // does not move it ahead of a peer already waiting.
    func testWaitingPeerKeepsItsPassWhenItAsksAgain() {
        let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
        _ = fixture.fetch(0, "holder")
        _ = fixture.fetch(1, "a-0")
        _ = fixture.fetch(2, "b-0")
        let pass = fixture.server.core.waitingServingPeers[fixture.clients[1].peer]?.pass
        XCTAssertEqual(pass, 1)
        for index in 1..<5 { _ = fixture.fetch(1, "a-\(index)") }
        XCTAssertEqual(fixture.server.core.waitingServingPeers[fixture.clients[1].peer]?.pass, pass)
        XCTAssertEqual(fixture.server.core.waitingServingPeers[fixture.clients[1].peer]?.count, 5)
        fixture.open()
        // Equal weights: the two peers alternate while both wait.
        XCTAssertEqual(
            fixture.server.volumeReads,
            ["holder", "a-0", "b-0", "a-1", "a-2", "a-3", "a-4"])
        XCTAssertServingIdle(fixture.server)
    }

    // A peer that joins the queue late starts one stride past the virtual
    // time, not at zero: it cannot claim the slots it did not wait for.
    func testLateJoinerStartsAtTheVirtualTime() {
        let fixture = ServingFixture(clients: 3, maxConcurrentContentRequests: 1)
        _ = fixture.fetch(0, "holder")
        for index in 0..<10 { _ = fixture.fetch(1, "early-\(index)") }
        for _ in 0..<6 { fixture.sim.releaseNextRead(fixture.server) }
        // Six grants to a weight-1 peer: the virtual time stands at 6.
        XCTAssertEqual(fixture.server.core.servingVirtualTime, 6)
        _ = fixture.fetch(2, "late-0")
        _ = fixture.fetch(2, "late-1")
        XCTAssertEqual(fixture.server.core.waitingServingPeers[fixture.clients[2].peer]?.pass, 7)
        fixture.open()
        XCTAssertEqual(
            Array(fixture.server.volumeReads.dropFirst(7)),
            ["early-6", "late-0", "early-7", "late-1", "early-8", "early-9"])
        XCTAssertServingIdle(fixture.server)
    }

    // The node's own reads take a free slot without queueing, and count
    // against the slots remote requests wait for.
    func testLocalReadTakesAFreeSlotWithoutQueueing() {
        let fixture = ServingFixture(clients: 1, maxConcurrentContentRequests: 1)
        let server = fixture.server
        server.volumes["mine"] = servingSmallVolume("mine")
        server.content["mine"] = Data("mine".utf8)

        let local = fixture.sim.request(
            .fetchVolume(rootCID: "mine", maximumArchiveBytes: .max, maximumEntries: .max), on: server)
        fixture.sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads, ["mine"])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(fixture.waiting, 0)

        // A remote request waits for the slot the local read holds.
        let remote = fixture.fetch(0, "remote")
        XCTAssertEqual(fixture.waiting, 1)
        XCTAssertEqual(server.volumeAuthorizations, [])

        // With no slot free, a second local read does not queue for one:
        // it never reaches storage.
        let second = fixture.sim.request(.fetchContent(rootCID: "mine", cids: []), on: server)
        fixture.sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.count, 0)
        XCTAssertEqual(fixture.waiting, 1)

        fixture.sim.releaseNextRead(server)
        XCTAssertEqual(
            fixture.sim.volume(local, on: server)?.entries,
            Dictionary(uniqueKeysWithValues: servingSmallVolume("mine").map { ($0.cid, $0.data) }))
        // The freed slot went to the waiting remote request.
        XCTAssertEqual(server.volumeAuthorizations, ["remote"])
        XCTAssertEqual(fixture.waiting, 0)
        fixture.open()
        XCTAssertTrue(fixture.served(remote, 0, "remote"))
        fixture.sim.cancel(second, on: server)
        fixture.sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }

    // A local read takes a free slot even while that slot's would-be waiters
    // do not exist yet: with a slot free it never waits behind anyone.
    func testLocalContentReadHoldsASlotRemoteRequestsWaitFor() {
        let fixture = ServingFixture(clients: 1, maxConcurrentContentRequests: 2)
        let server = fixture.server
        server.content["mine"] = Data("mine".utf8)
        _ = fixture.fetch(0, "holder")
        let local = fixture.sim.request(.fetchContent(rootCID: "mine", cids: []), on: server)
        fixture.sim.runHoldingReads(server)
        XCTAssertEqual(server.contentReads.map(\.rootCID), ["mine"])
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 2)
        let waiter = fixture.fetch(0, "waiter")
        XCTAssertEqual(fixture.waiting, 1)
        fixture.open()
        XCTAssertEqual(fixture.sim.result(of: local, on: server)?.content?.entries, ["mine": Data("mine".utf8)])
        XCTAssertTrue(fixture.served(waiter, 0, "waiter"))
        XCTAssertServingIdle(server)
    }

    // MARK: - Property: shares follow weights, and everyone is served

    /// Many peers with random credit and random backlogs contend for a few
    /// slots. While every peer still has requests waiting, each peer's share
    /// of the grants tracks its weight to within stride scheduling's bound;
    /// each peer's own requests are granted in arrival order; the virtual
    /// time never moves backwards; and every request is served in the end.
    func testWeightedSharesConvergeAndEveryRequestIsServed() {
        for seed in UInt64(1)...6 {
            var random = CoreRandom.seeded(seed &* 0x5DEECE66D)
            let sim = Simulation(seed: seed)
            let slots = Int.random(in: 1...3, using: &random)
            let server = sim.node(requestTimeout: .seconds(3_600), maxConcurrentContentRequests: slots)
            server.volumes["root"] = [ContentEntry(cid: "root", data: Data("bytes".utf8))]
            let holder = ServingRawPeer(sim, to: server, index: 0)
            let peerCount = Int.random(in: 3...9, using: &random)
            let peers = (1...peerCount).map { ServingRawPeer(sim, to: server, index: $0) }
            var counts: [Int] = []
            for peer in peers {
                // A third of the peers are strangers; the rest hold up to 1 GiB of credit.
                let credit = Int.random(in: 0..<3, using: &random) == 0
                    ? 0 : pow(2, Double.random(in: 0...30, using: &random))
                server.ledger.setServingPriority(credit, for: peer.peer)
                counts.append(Int.random(in: 20...120, using: &random))
            }
            let weights = peers.map { server.core.servingWeight(of: $0.peer) }
            let totalWeight = weights.reduce(0, +)

            // Every slot is busy, then every peer queues its backlog, interleaved.
            server.stallsStorage = true
            for id in 1...slots { holder.send(.volumeRequest(requestID: UInt64(id), rootCID: "root")) }
            sim.runHoldingReads(server)
            XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, slots, "seed \(seed)")
            var sent = [Int](repeating: 0, count: peerCount)
            var unsent = peers.indices.filter { counts[$0] > 0 }
            while !unsent.isEmpty {
                let pick = Int.random(in: 0..<unsent.count, using: &random)
                let index = unsent[pick]
                sent[index] += 1
                peers[index].send(.volumeRequest(requestID: UInt64(sent[index]), rootCID: "root"))
                if sent[index] == counts[index] { unsent.remove(at: pick) }
            }
            let total = counts.reduce(0, +)
            XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, total, "seed \(seed)")

            // Drain, watching the virtual time.
            sim.releaseStorage(server)
            var lastVirtualTime = server.core.servingVirtualTime
            var steps = 0
            while !server.core.serving.isEmpty, steps < 100_000 {
                sim.run(for: .milliseconds(1))
                XCTAssertGreaterThanOrEqual(server.core.servingVirtualTime, lastVirtualTime, "seed \(seed)")
                lastVirtualTime = server.core.servingVirtualTime
                steps += 1
            }
            sim.run(for: .seconds(1))

            // Grants, in order, by peer.
            let indexOf = Dictionary(uniqueKeysWithValues: peers.enumerated().map { ($1.peer, $0) })
            let grants = server.volumeAuthorizationPeers.compactMap { indexOf[$0] }
            XCTAssertEqual(grants.count, total, "seed \(seed)")

            // While all peers wait, peer i has had floor(t * w_i) grants at
            // virtual time t, so after N grants its count is within
            // (-1, n * w_i / W) of its exact share N * w_i / W.
            var granted = [Int](repeating: 0, count: peerCount)
            for (position, index) in grants.enumerated() {
                granted[index] += 1
                let n = Double(position + 1)
                for other in peers.indices {
                    let share = n * weights[other] / totalWeight
                    let error = Double(granted[other]) - share
                    XCTAssertGreaterThan(error, -1 - 1e-9, "seed \(seed) grant \(position) peer \(other)")
                    XCTAssertLessThan(
                        error, Double(peerCount) * weights[other] / totalWeight + 1e-9,
                        "seed \(seed) grant \(position) peer \(other)")
                }
                // Past the first exhausted backlog the remaining peers split its share.
                if granted[index] == counts[index] { break }
            }

            // Every request of every peer was served, each peer's in arrival order.
            holder.read()
            XCTAssertEqual(holder.chunks.count, slots, "seed \(seed)")
            for (index, peer) in peers.enumerated() {
                peer.read()
                XCTAssertEqual(peer.unavailable, [], "seed \(seed) peer \(index)")
                XCTAssertEqual(
                    peer.chunks.map(\.requestID), (1...counts[index]).map(UInt64.init),
                    "seed \(seed) peer \(index)")
            }
            XCTAssertServingIdle(server)
        }
    }
}
