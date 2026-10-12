import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// Two connected nodes: `client` dialled `server`.
private struct ServingPair {
    let sim = Simulation()
    let server: Simulation.Node
    let client: Simulation.Node

    init(
        volumes: [String: [ContentEntry]] = [:],
        bundles: [String: [String]] = [:],
        serverInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes,
        serverConcurrentContentRequests: Int = 64,
        serverRequestTimeout: Duration = .seconds(3_600)
    ) {
        server = sim.node(
            requestTimeout: serverRequestTimeout,
            maxConcurrentContentRequests: serverConcurrentContentRequests,
            maxInFlightVolumeBytes: serverInFlightVolumeBytes)
        client = sim.node(requestTimeout: .seconds(3_600))
        server.volumes = volumes
        server.bundles = bundles
        sim.connect(client, server)
    }

    func fetch(_ root: String) -> RequestID {
        let request = sim.fetchVolume(root, from: server, on: client)
        if server.stallsStorage { sim.runHoldingReads(server) }
        return request
    }

    func fetchBundle(_ root: String) -> RequestID {
        let request = sim.request(
            .fetchVolumeBundle(rootCID: root, from: [sim.session(client, to: server)]), on: client)
        if server.stallsStorage { sim.runHoldingReads(server) }
        return request
    }

    func volume(_ request: RequestID) -> AttributedVolumeResponse? {
        sim.volume(request, on: client)
    }

    func bundle(_ request: RequestID) -> AttributedVolumeBundleResponse? {
        sim.result(of: request, on: client)?.bundle
    }

    func open() {
        sim.releaseStorage(server)
        sim.run(for: .seconds(5))
    }
}

private func smallVolumes(_ roots: [String]) -> [String: [ContentEntry]] {
    Dictionary(uniqueKeysWithValues: roots.map { ($0, servingSmallVolume($0)) })
}

private func archiveBytes(_ entries: [ContentEntry], _ root: String) -> Int {
    VolumeArchive.encode(entries: entries, rootCID: root)?.data.count ?? 0
}

private let worstCase = MessageLimits.maxVolumeArchiveBytes

final class VolumeServingSimulationTests: XCTestCase {
    // small Volumes being sent hold their own size, so many share the budget
    func testSendingVolumesHoldActualSize() {
        let roots = (0..<8).map { "small-\($0)" }
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600))
        server.volumes = smallVolumes(roots)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        // Stall every send so all eight are in flight at once. A worst-case
        // reservation each (64 MiB, 128 MiB budget) would admit only two.
        peer.stopReading()
        for (index, root) in roots.enumerated() {
            peer.send(.volumeRequest(requestID: UInt64(index + 1), rootCID: root))
        }
        sim.run(for: .seconds(1))
        let total = roots.reduce(0) { $0 + archiveBytes(servingSmallVolume($1), $1) }
        XCTAssertTrue(total > 0 && total < worstCase)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, total)
        XCTAssertEqual(server.core.diagnostics.servingVolumeReadsWaiting, 0)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 8)
        XCTAssertEqual(server.volumeReads.count, 8)
        XCTAssertTrue(peer.read().isEmpty)

        peer.resumeReading()
        sim.run(for: .seconds(1))
        peer.read()
        for (index, root) in roots.enumerated() {
            XCTAssertEqual(
                peer.archive(requestID: UInt64(index + 1), rootCID: root),
                VolumeArchive.encode(entries: servingSmallVolume(root), rootCID: root)?.data)
        }
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
    }

    // a read beyond capacity waits its turn instead of being refused
    func testBurstWaitsForReadCapacity() {
        // Room for exactly one worst-case read.
        let pair = ServingPair(
            volumes: smallVolumes(["first", "second"]), serverInFlightVolumeBytes: worstCase)
        pair.server.stallsStorage = true
        let first = pair.fetch("first")
        XCTAssertEqual(pair.server.volumeReads, ["first"])
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)
        let second = pair.fetch("second")
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 1)
        XCTAssertEqual(pair.server.volumeReads, ["first"])
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)

        pair.open()
        XCTAssertEqual(pair.volume(first), servingExpectedVolume("first", servedBy: pair.server.peer))
        XCTAssertEqual(pair.volume(second), servingExpectedVolume("second", servedBy: pair.server.peer))
        XCTAssertServingIdle(pair.server)
    }

    // a request that waits for a slot longer than requestTimeout is still served
    func testWaitingForSlotOutlivesRequestTimeout() {
        let pair = ServingPair(
            volumes: smallVolumes(["first", "second"]),
            serverConcurrentContentRequests: 1,
            serverRequestTimeout: .seconds(1))
        pair.server.stallsStorage = true
        _ = pair.fetch("first")
        XCTAssertEqual(pair.server.volumeReads, ["first"])
        let second = pair.fetch("second")
        XCTAssertEqual(pair.server.core.diagnostics.servingRequestsWaiting, 1)
        pair.sim.runHoldingReads(pair.server, for: .milliseconds(2_500))
        XCTAssertEqual(pair.server.core.diagnostics.servingRequestsWaiting, 1)
        // Only the read that held its capacity past the deadline was cancelled.
        XCTAssertEqual(pair.server.cancelledJobs.count, 1)

        pair.open()
        XCTAssertEqual(pair.volume(second), servingExpectedVolume("second", servedBy: pair.server.peer))
        XCTAssertEqual(pair.server.cancelledJobs.count, 1)
        XCTAssertServingIdle(pair.server)
    }

    // waiting reads are admitted oldest first as capacity frees
    func testWaitersAreAdmittedInOrder() {
        let roots = ["a", "b", "c", "d"]
        let pair = ServingPair(volumes: smallVolumes(roots), serverInFlightVolumeBytes: worstCase)
        pair.server.stallsStorage = true
        var fetches: [RequestID] = []
        for (index, root) in roots.enumerated() {
            fetches.append(pair.fetch(root))
            XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, index)
        }
        // One at a time: each read frees room for exactly the next.
        for index in roots.indices.dropLast() {
            pair.sim.releaseNextRead(pair.server)
            XCTAssertEqual(pair.server.volumeReads, Array(roots.prefix(index + 2)))
            XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)
        }
        pair.open()
        for (root, fetch) in zip(roots, fetches) {
            XCTAssertEqual(pair.volume(fetch), servingExpectedVolume(root, servedBy: pair.server.peer))
        }
        XCTAssertEqual(pair.server.volumeReads, roots)
        XCTAssertServingIdle(pair.server)
    }

    // a waiting read is withdrawn when its requester disconnects
    func testWaiterReleasedOnDisconnect() {
        let pair = ServingPair(
            volumes: smallVolumes(["held", "queued"]), serverInFlightVolumeBytes: worstCase)
        pair.server.stallsStorage = true
        let held = pair.fetch("held")
        XCTAssertEqual(pair.server.volumeReads, ["held"])
        let queued = pair.fetch("queued")
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 1)

        pair.sim.stop(pair.client)
        pair.sim.runHoldingReads(pair.server)
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 0)
        // The read that is still out keeps its slot and its bytes.
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)
        XCTAssertEqual(pair.server.core.diagnostics.servingSlotsHeld, 1)
        pair.open()
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, 0)
        // The queued read never reached storage.
        XCTAssertEqual(pair.server.volumeReads, ["held"])
        XCTAssertEqual(pair.volume(held), .empty)
        XCTAssertEqual(pair.volume(queued), .empty)
        XCTAssertServingIdle(pair.server)
    }

    // stopping the server releases waiting reads without hanging
    func testStopReleasesWaiters() {
        let pair = ServingPair(
            volumes: smallVolumes(["held", "queued"]), serverInFlightVolumeBytes: worstCase)
        pair.server.stallsStorage = true
        let held = pair.fetch("held")
        XCTAssertEqual(pair.server.volumeReads, ["held"])
        let queued = pair.fetch("queued")
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 1)

        pair.sim.stop(pair.server)
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 0)
        pair.open()
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(pair.server.volumeReads, ["held"])
        XCTAssertEqual(pair.volume(held), .empty)
        XCTAssertEqual(pair.volume(queued), .empty)
        XCTAssertServingIdle(pair.server)
    }

    // a budget smaller than one worst-case Volume still serves, one read at a time
    func testSmallBudgetServesAlone() {
        let pair = ServingPair(
            volumes: smallVolumes(["root", "next"]), serverInFlightVolumeBytes: 1024 * 1024)
        let alone = pair.fetch("root")
        pair.sim.run(for: .seconds(1))
        XCTAssertEqual(pair.volume(alone), servingExpectedVolume("root", servedBy: pair.server.peer))
        XCTAssertServingIdle(pair.server)

        // Two at once: the second waits for the first, and both are served.
        pair.server.stallsStorage = true
        let first = pair.fetch("root")
        let second = pair.fetch("next")
        XCTAssertEqual(pair.server.volumeReads, ["root", "root"])
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 1)
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)
        pair.open()
        XCTAssertEqual(pair.volume(first), servingExpectedVolume("root", servedBy: pair.server.peer))
        XCTAssertEqual(pair.volume(second), servingExpectedVolume("next", servedBy: pair.server.peer))
        XCTAssertServingIdle(pair.server)
    }

    // MARK: - Reservations

    // The default budget holds two worst-case reads and the third waits. A
    // Volume that has been read holds only its archive, and a worst-case
    // read fits again once that is sent.
    func testReadReservationIsWorstCaseThenShrinksToTheArchive() {
        let roots = ["a", "b", "c"]
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600))
        server.volumes = smallVolumes(roots)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.stopReading()
        server.stallsStorage = true
        for (index, root) in roots.enumerated() {
            peer.send(.volumeRequest(requestID: UInt64(index + 1), rootCID: root))
        }
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads, ["a", "b"])
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, 2 * worstCase)
        XCTAssertEqual(server.core.diagnostics.servingVolumeReadsWaiting, 1)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 3)

        // "a" is read and encoded; its send stalls, holding only its archive.
        // Those few bytes still leave no room for a third worst case.
        sim.releaseNextRead(server)
        XCTAssertEqual(
            server.core.diagnostics.reservedServingVolumeBytes,
            worstCase + archiveBytes(servingSmallVolume("a"), "a"))
        XCTAssertEqual(server.volumeReads, ["a", "b"])
        XCTAssertEqual(server.core.diagnostics.servingVolumeReadsWaiting, 1)

        // Sent, "a" gives its bytes back and "c" is admitted.
        peer.resumeReading()
        sim.runHoldingReads(server)
        XCTAssertEqual(server.volumeReads, ["a", "b", "c"])
        XCTAssertEqual(server.core.diagnostics.servingVolumeReadsWaiting, 0)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, 2 * worstCase)

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.chunks.map(\.rootCID), roots)
        XCTAssertServingIdle(server)
    }

    // A Volume the source does not hold, or cannot encode, gives its whole
    // reservation back and is refused.
    func testUnreadableVolumeReleasesItsReservationAndIsRefused() {
        let sim = Simulation()
        let server = sim.node()
        // No entry for the root; a member whose identifier Ivy does not accept.
        server.volumes["rootless"] = [ContentEntry(cid: "other", data: Data("x".utf8))]
        server.volumes["bad-member"] = [
            ContentEntry(cid: "bad-member", data: Data("x".utf8)),
            ContentEntry(cid: "caf\u{e9}", data: Data("x".utf8)),
        ]
        server.volumes["twice"] = [
            ContentEntry(cid: "twice", data: Data("x".utf8)),
            ContentEntry(cid: "twice", data: Data("y".utf8)),
        ]
        let peer = ServingRawPeer(sim, to: server, index: 1)
        for (index, root) in ["absent", "rootless", "bad-member", "twice"].enumerated() {
            peer.send(.volumeRequest(requestID: UInt64(index + 1), rootCID: root))
        }
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.unavailable, [1, 2, 3, 4])
        XCTAssertEqual(peer.chunks, [])
        XCTAssertEqual(server.volumeReads.count, 4)
        XCTAssertServingIdle(server)
    }

    // MARK: - Authorization

    // A Volume is authorized before it is read, as the session that asked.
    func testVolumeAuthorizationPrecedesStorage() {
        let pair = ServingPair(volumes: smallVolumes(["open", "closed"]))
        var asked: [(AuthenticatedPeer, String)] = []
        pair.server.authorize = { peer, root in
            asked.append((peer, root))
            return root == "open"
        }
        let closed = pair.fetch("closed")
        let open = pair.fetch("open")
        pair.sim.run(for: .seconds(1))
        XCTAssertEqual(pair.volume(closed), .empty)
        XCTAssertEqual(pair.volume(open), servingExpectedVolume("open", servedBy: pair.server.peer))
        XCTAssertEqual(asked.map(\.1), ["closed", "open"])
        XCTAssertEqual(asked.first?.0, pair.sim.session(pair.server, to: pair.client))
        // The refused Volume never reached storage and reserved nothing.
        XCTAssertEqual(pair.server.volumeReads, ["open"])
        XCTAssertServingIdle(pair.server)
    }

    // Authorization is untimed: `requestTimeout` starts when the read holds
    // its reservation.
    func testVolumeAuthorizationIsNotTimed() {
        let pair = ServingPair(volumes: smallVolumes(["root"]), serverRequestTimeout: .seconds(1))
        pair.server.stallsStorage = true
        let fetch = pair.sim.fetchVolume("root", from: pair.server, on: pair.client)
        pair.sim.run(for: .seconds(5))
        XCTAssertEqual(pair.server.volumeAuthorizations, ["root"])
        XCTAssertEqual(pair.server.cancelledJobs, [])
        XCTAssertEqual(pair.server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, 0)
        pair.open()
        XCTAssertEqual(pair.volume(fetch), servingExpectedVolume("root", servedBy: pair.server.peer))
        XCTAssertEqual(pair.server.cancelledJobs, [])
        XCTAssertServingIdle(pair.server)
    }

    // A session that ends while its Volume is being authorized ends the
    // request without a read; the authorization keeps the slot until it exits.
    func testSessionLossDuringAuthorizationReadsNothing() {
        let pair = ServingPair(volumes: smallVolumes(["root"]))
        pair.server.stallsStorage = true
        let fetch = pair.sim.fetchVolume("root", from: pair.server, on: pair.client)
        pair.sim.run(for: .milliseconds(100))
        XCTAssertEqual(pair.server.volumeAuthorizations, ["root"])
        pair.sim.stop(pair.client)
        pair.sim.run(for: .milliseconds(100))
        XCTAssertEqual(pair.server.cancelledJobs.count, 1)
        XCTAssertEqual(pair.server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(pair.server.core.diagnostics.jobsOutstanding, 1)
        pair.open()
        XCTAssertEqual(pair.server.volumeReads, [])
        XCTAssertEqual(pair.volume(fetch), .empty)
        XCTAssertServingIdle(pair.server)
    }

    // MARK: - Deadlines

    // `requestTimeout` does not run while a read waits for its reservation:
    // it starts once the read holds it.
    func testWaitingForReadReservationOutlivesRequestTimeout() {
        let pair = ServingPair(
            volumes: smallVolumes(["first", "second"]),
            serverInFlightVolumeBytes: worstCase,
            serverRequestTimeout: .seconds(1))
        pair.server.stallsStorage = true
        _ = pair.fetch("first")
        let second = pair.fetch("second")
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 1)
        pair.sim.runHoldingReads(pair.server, for: .milliseconds(2_500))
        // The first read was cancelled at its deadline and, ignoring that,
        // still holds its bytes; the second still waits, uncancelled.
        XCTAssertEqual(pair.server.cancelledJobs.count, 1)
        XCTAssertEqual(pair.server.core.diagnostics.servingVolumeReadsWaiting, 1)
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)
        XCTAssertEqual(pair.server.volumeReads, ["first"])

        pair.open()
        XCTAssertEqual(pair.volume(second), servingExpectedVolume("second", servedBy: pair.server.peer))
        XCTAssertEqual(pair.server.cancelledJobs.count, 1)
        XCTAssertServingIdle(pair.server)
    }

    // `cancelJob` is emitted at the deadline, and a read that ignores it
    // keeps its slot and its bytes until it finishes; the requester then
    // hears nothing more of the Volume.
    func testReadPastTheDeadlineIsCancelledAndKeepsItsCapacityUntilItFinishes() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(2), maxConcurrentContentRequests: 1)
        server.volumes = smallVolumes(["root", "next"])
        let peer = ServingRawPeer(sim, to: server, index: 1)
        server.stallsStorage = true
        peer.send(.volumeRequest(requestID: 1, rootCID: "root"))
        sim.runHoldingReads(server, for: .zero)
        let started = sim.now
        XCTAssertEqual(server.volumeReads, ["root"])
        let read = server.startedJobs.last!.id

        sim.run(until: { !server.cancelledJobs.isEmpty }, timeout: .seconds(10))
        XCTAssertEqual(server.cancelledJobs, [read])
        XCTAssertEqual(sim.now - started, .seconds(2))

        // Another request waits for the slot the cancelled read still holds.
        peer.send(.volumeRequest(requestID: 2, rootCID: "next"))
        sim.runHoldingReads(server, for: .seconds(5))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, worstCase)
        XCTAssertEqual(server.core.diagnostics.jobsOutstanding, 1)
        XCTAssertEqual(server.cancelledJobs, [read])

        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.chunks.map(\.requestID), [2])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
    }

    // a stalled authenticated Volume writer releases its reservation at the deadline
    func testStalledVolumeWriterTimesOut() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(1))
        let entries = [ContentEntry(
            cid: "root",
            data: Data(repeating: 0xa5, count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1))]
        // While it is sent, a Volume holds its encoded size, not the worst case.
        let size = archiveBytes(entries, "root")
        server.volumes["root"] = entries
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.stopReading()
        peer.send(.volumeRequest(requestID: 1, rootCID: "root"))
        sim.run(for: .milliseconds(500))
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, size)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(server.cancelledJobs, [])
        XCTAssertServingIdle(server)

        // Nothing of the Volume was written, and nothing follows.
        peer.resumeReading()
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.chunks, [])
    }

    // MARK: - The chunk cursor

    // Chunks go out in order, each within the frame size the peer said it
    // accepts, and together they are the archive.
    func testChunksAreInOrderWithinTheNegotiatedFrameSize() {
        let frame: UInt32 = 32 * 1024
        let sim = Simulation()
        let server = sim.node()
        let entries = volumeEntries(root: "vol", members: 12, bytesEach: 20_000)
        server.volumes["vol"] = entries
        let peer = ServingRawPeer(sim, to: server, index: 1, maxFrameSize: frame)
        let handshakeFrames = peer.frameSizes.count
        peer.send(.volumeRequest(requestID: 9, rootCID: "vol"))
        sim.run(for: .seconds(2))
        peer.read()

        let archive = VolumeArchive.encode(entries: entries, rootCID: "vol")!
        let payloadBytes = Message.volumeChunkDataBudget(rootCID: "vol", maxFrameSize: frame, relayed: false)!
        let count = (archive.data.count + payloadBytes - 1) / payloadBytes
        XCTAssertGreaterThan(count, 4)
        let chunks = peer.chunks
        XCTAssertEqual(chunks.map(\.index), Array(0..<count))
        XCTAssertTrue(chunks.allSatisfy {
            $0.requestID == 9 && $0.rootCID == "vol" && $0.count == count
                && $0.totalEntries == entries.count && $0.totalBytes == archive.data.count
        })
        // Every chunk but the last fills its frame exactly.
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.payload.count == payloadBytes })
        XCTAssertEqual(peer.archive(requestID: 9, rootCID: "vol"), archive.data)
        let volumeFrames = peer.frameSizes.dropFirst(handshakeFrames)
        XCTAssertEqual(volumeFrames.count, count)
        XCTAssertEqual(volumeFrames.max(), Int(frame))
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
    }

    // The server's own frame size does not shrink what it sends a peer that
    // accepts more, and a peer that accepts less is sent less.
    func testChunkSizeFollowsThePeersAdvertisedFrameSize() {
        let sim = Simulation()
        let server = sim.node(protocolMaxFrameSize: 256 * 1024)
        let entries = volumeEntries(root: "vol", members: 9, bytesEach: 100_000)
        server.volumes["vol"] = entries
        let archive = VolumeArchive.encode(entries: entries, rootCID: "vol")!
        let frames: [UInt32] = [128 * 1024, 1024 * 1024]
        for (index, frame) in frames.enumerated() {
            let peer = ServingRawPeer(sim, to: server, index: index + 1, maxFrameSize: frame)
            peer.send(.volumeRequest(requestID: 1, rootCID: "vol"))
            sim.run(for: .seconds(2))
            peer.read()
            let payloadBytes = Message.volumeChunkDataBudget(rootCID: "vol", maxFrameSize: frame, relayed: false)!
            XCTAssertEqual(peer.chunks.first?.payload.count, min(payloadBytes, archive.data.count))
            XCTAssertEqual(peer.chunks.count, (archive.data.count + payloadBytes - 1) / payloadBytes)
            XCTAssertEqual(peer.archive(requestID: 1, rootCID: "vol"), archive.data)
        }
        XCTAssertServingIdle(server)
    }

    // The cursor stops when the connection stops taking records and picks
    // up from the same chunk on `writable`.
    func testChunkCursorStopsOnBackpressureAndResumesOnWritable() {
        let frame: UInt32 = 16 * 1024
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600))
        let entries = volumeEntries(root: "vol", members: 30, bytesEach: 20_000)
        server.volumes["vol"] = entries
        let archive = VolumeArchive.encode(entries: entries, rootCID: "vol")!
        let peer = ServingRawPeer(sim, to: server, index: 1, maxFrameSize: frame)
        let request = InboundContentRequest(
            peer: peer.peer, link: server.core.sessions[peer.key]!.link, requestID: 1)

        // The peer stops taking bytes: the server writes until it is past
        // its high-water mark and no further.
        sim.setRawStalled(true, peer.connection, at: server)
        peer.send(.volumeRequest(requestID: 1, rootCID: "vol"))
        sim.run(for: .seconds(30))
        peer.read()
        let firstBurst = peer.chunks.count
        let written = (Int(frame) + 4) * firstBurst
        XCTAssertGreaterThan(written, IvyCore.writeHighWaterMark)
        XCTAssertLessThanOrEqual(written - (Int(frame) + 4), IvyCore.writeHighWaterMark)
        XCTAssertEqual(peer.chunks.map(\.index), Array(0..<firstBurst))
        XCTAssertEqual(server.core.serving[request]?.phase, .sending)
        XCTAssertEqual(server.core.serving[request]?.chunkIndex, firstBurst)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, archive.data.count)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)

        // One `writable`: one more burst, from where it stopped.
        sim.send(.writable(peer.connection), to: server)
        peer.read()
        XCTAssertEqual(peer.chunks.count, 2 * firstBurst)
        XCTAssertEqual(peer.chunks.map(\.index), Array(0..<(2 * firstBurst)))
        XCTAssertEqual(server.core.serving[request]?.phase, .sending)

        // A peer that reads again gets the rest.
        peer.resumeReading()
        sim.run(for: .seconds(5))
        peer.read()
        XCTAssertEqual(peer.chunks.map(\.index), Array(0..<peer.chunks[0].count))
        XCTAssertEqual(peer.archive(requestID: 1, rootCID: "vol"), archive.data)
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertServingIdle(server)
    }

    // Two Volumes to one stalled peer both resume, each from its own cursor.
    func testTwoStalledVolumesBothResume() {
        let frame: UInt32 = 16 * 1024
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600))
        for root in ["one", "two"] {
            server.volumes[root] = volumeEntries(root: root, members: 20, bytesEach: 20_000)
        }
        let peer = ServingRawPeer(sim, to: server, index: 1, maxFrameSize: frame)
        sim.setRawStalled(true, peer.connection, at: server)
        peer.send(.volumeRequest(requestID: 1, rootCID: "one"))
        peer.send(.volumeRequest(requestID: 2, rootCID: "two"))
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 2)
        XCTAssertEqual(server.core.serving.values.filter { $0.phase == .sending }.count, 2)
        peer.resumeReading()
        sim.run(for: .seconds(5))
        peer.read()
        for root in ["one", "two"] {
            XCTAssertEqual(
                peer.archive(requestID: root == "one" ? 1 : 2, rootCID: root),
                VolumeArchive.encode(entries: server.volumes[root]!, rootCID: root)?.data)
        }
        XCTAssertServingIdle(server)
    }

    // Losing the session mid-Volume ends it silently and returns everything.
    func testSessionLossMidVolumeEndsItSilently() {
        let frame: UInt32 = 16 * 1024
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600))
        server.volumes["vol"] = volumeEntries(root: "vol", members: 30, bytesEach: 20_000)
        let peer = ServingRawPeer(sim, to: server, index: 1, maxFrameSize: frame)
        sim.setRawStalled(true, peer.connection, at: server)
        peer.send(.volumeRequest(requestID: 1, rootCID: "vol"))
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertGreaterThan(server.core.diagnostics.reservedServingVolumeBytes, 0)
        peer.read()
        let sentBefore = peer.inbox.count

        peer.close()
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
        XCTAssertTrue(server.core.writabilityWaiters.isEmpty)
        XCTAssertEqual(server.cancelledJobs, [])
        peer.read()
        XCTAssertEqual(peer.inbox.count, sentBefore)
    }

    // a complete Volume larger than one frame crosses an authenticated session
    func testMultiFrameVolume() {
        let rootBytes = Data(repeating: 0xa5, count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1)
        let childBytes = Data("child".utf8)
        let pair = ServingPair(volumes: ["root": [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "child", data: childBytes),
        ]])
        let fetch = pair.fetch("root")
        pair.sim.run(for: .seconds(5))
        XCTAssertEqual(pair.volume(fetch), AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": rootBytes, "child": childBytes],
            servedBy: pair.server.peer))
        XCTAssertServingIdle(pair.server)
    }

    // A Volume's chunks leave room for the route's overhead: on a relayed
    // session each is smaller by the relay packet and the carrier's record.
    func testRelayedVolumeChunksSubtractTheRouteOverhead() throws {
        let frame: UInt32 = 64 * 1024 + 4096
        let sim = Simulation()
        let relay = sim.node(relayEnabled: true, protocolMaxFrameSize: frame)
        let server = sim.node(carriers: [relay.endpoint], protocolMaxFrameSize: frame)
        let client = sim.node(
            carriers: [relay.endpoint], requestTimeout: .seconds(3_600), protocolMaxFrameSize: frame)
        let entries = volumeEntries(root: "vol", members: 10, bytesEach: 30_000)
        server.volumes["vol"] = entries
        sim.run(for: .seconds(5))
        XCTAssertEqual(sim.await(.connectViaRelay(server.endpoint), on: client), .connect(.connected))
        sim.run(for: .seconds(1))
        let session = try XCTUnwrap(server.core.sessions[client.key])
        XCTAssertEqual(server.core.links[session.link]?.isDirect, false)

        let before = sim.trace.count
        let response = sim.await(
            .fetchVolumeFrom(
                sim.session(client, to: server),
                rootCID: "vol", maximumArchiveBytes: .max, maximumEntries: .max),
            on: client)?.volume
        XCTAssertEqual(response?.entries.count, entries.count)
        XCTAssertEqual(response?.servedBy, server.peer)

        // The largest record the server wrote is one full frame, carrier
        // envelope included: the chunk inside it was cut to leave room.
        let direct = Message.volumeChunkDataBudget(rootCID: "vol", maxFrameSize: frame, relayed: false)!
        let relayed = Message.volumeChunkDataBudget(rootCID: "vol", maxFrameSize: frame, relayed: true)!
        XCTAssertEqual(direct - relayed, 1 + 32 + 4 + SessionWireRecord.dataRecordOverhead)
        let written = sim.trace[before...].compactMap { entry -> Int? in
            guard entry.node == server.id, case .write(_, let bytes) = entry.effect else { return nil }
            return bytes.count - 4
        }
        XCTAssertEqual(written.max(), Int(frame))
        let archive = VolumeArchive.encode(entries: entries, rootCID: "vol")!
        XCTAssertEqual(
            written.filter { $0 > 1024 }.count, (archive.data.count + relayed - 1) / relayed)
        sim.run(for: .seconds(1))
        XCTAssertServingIdle(server)
    }
}

final class VolumeBundleServingSimulationTests: XCTestCase {
    private static let roots = ["root", "member-a", "member-b"]
    private static let volumes = smallVolumes(roots)

    // one request returns the bundle's Volumes in order, leaving out one the server cannot send
    func testBundleRoundTrip() {
        let pair = ServingPair(
            volumes: Self.volumes, bundles: ["root": ["root", "member-a", "absent", "member-b"]])
        let fetch = pair.fetchBundle("root")
        pair.sim.run(for: .seconds(2))
        XCTAssertEqual(pair.bundle(fetch), AttributedVolumeBundleResponse(
            volumes: Self.roots.map { servingExpectedVolume($0, servedBy: pair.server.peer) },
            ended: true))
        XCTAssertEqual(pair.server.volumeReads, ["root", "member-a", "absent", "member-b"])
        XCTAssertServingIdle(pair.server)
    }

    // a peer whose source bundles nothing says so at once, and still serves the Volume
    func testNoBundleIsAnsweredNotTimedOut() {
        let pair = ServingPair(volumes: Self.volumes)
        let started = pair.sim.now
        let bundle = pair.fetchBundle("root")
        pair.sim.run(until: { pair.bundle(bundle) != nil })
        XCTAssertEqual(
            pair.bundle(bundle), AttributedVolumeBundleResponse(volumes: [], noBundle: true, ended: true))
        // A Volume the peer does not hold is refused, not answered "no bundle".
        let absent = pair.fetch("absent")
        pair.sim.run(until: { pair.volume(absent) != nil })
        XCTAssertEqual(pair.volume(absent), .empty)
        XCTAssertLessThan(pair.sim.now - started, .seconds(1))
        let single = pair.fetch("root")
        pair.sim.run(for: .seconds(1))
        XCTAssertEqual(pair.volume(single), servingExpectedVolume("root", servedBy: pair.server.peer))
        // The bundle was looked up and nothing of it read.
        XCTAssertEqual(pair.server.bundleListings, ["root"])
        XCTAssertEqual(pair.server.volumeReads, ["absent", "root"])
        XCTAssertServingIdle(pair.server)
    }

    // a requester that disconnects mid-bundle releases the serving slot and its bytes
    func testDisconnectReleasesServing() {
        let pair = ServingPair(volumes: Self.volumes, bundles: ["root": Self.roots])
        pair.server.stallsStorage = true
        let fetch = pair.fetchBundle("root")
        XCTAssertEqual(pair.server.volumeReads, ["root"])
        XCTAssertEqual(pair.server.core.diagnostics.reservedServingVolumeBytes, worstCase)

        pair.sim.stop(pair.client)
        pair.sim.runHoldingReads(pair.server)
        XCTAssertFalse(pair.server.core.connectedPeers.contains(pair.client.peer))
        pair.open()
        XCTAssertServingIdle(pair.server)
        // The Volumes after the interrupted one were never read.
        XCTAssertEqual(pair.server.volumeReads, ["root"])
        XCTAssertEqual(pair.server.volumeAuthorizations, ["root"])
        XCTAssertEqual(pair.bundle(fetch)?.volumes, [])
        XCTAssertEqual(pair.bundle(fetch)?.ended, false)
    }

    // The requester's half of the test above: a bundle that was asked of a
    // peer and cut short by this node stopping is an answer that did not
    // end, not a request that was never sent.
    func testBundleCutShortByStoppingWasStillSent() {
        let pair = ServingPair(volumes: Self.volumes, bundles: ["root": Self.roots])
        pair.server.stallsStorage = true
        let fetch = pair.fetchBundle("root")
        XCTAssertEqual(pair.server.volumeReads, ["root"])
        pair.sim.stop(pair.client)
        // Nothing arrived, and the answer did not end.
        XCTAssertEqual(pair.bundle(fetch), .empty)
    }

    // another peer's waiting request is served between a bundle's Volumes
    func testBundleYieldsItsSlotBetweenVolumes() {
        var volumes = Self.volumes
        volumes["other"] = servingSmallVolume("other")
        let pair = ServingPair(
            volumes: volumes, bundles: ["root": Self.roots], serverConcurrentContentRequests: 1)
        let second = pair.sim.node(requestTimeout: .seconds(3_600))
        pair.sim.connect(second, pair.server)
        pair.server.stallsStorage = true
        let bundle = pair.fetchBundle("root")
        XCTAssertEqual(pair.server.volumeReads, ["root"])
        let other = pair.sim.fetchVolume("other", from: pair.server, on: second)
        pair.sim.runHoldingReads(pair.server)
        XCTAssertEqual(pair.server.core.diagnostics.servingRequestsWaiting, 1)

        // The root's Volume goes out; the bundle queues again behind the waiter.
        pair.sim.releaseNextRead(pair.server)
        XCTAssertEqual(pair.server.volumeReads, ["root", "other"])
        XCTAssertEqual(pair.server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(pair.server.core.diagnostics.servingSlotsHeld, 1)
        pair.open()
        XCTAssertEqual(pair.sim.volume(other, on: second), servingExpectedVolume("other", servedBy: pair.server.peer))
        XCTAssertEqual(pair.bundle(bundle)?.volumes.map(\.rootCID), Self.roots)
        XCTAssertEqual(pair.bundle(bundle)?.ended, true)
        XCTAssertEqual(pair.server.volumeReads, ["root", "other", "member-a", "member-b"])
        XCTAssertServingIdle(pair.server)
    }

    // MARK: - Beyond the reference suite

    // On the wire: each Volume's chunks in turn, the root's own first, then the end.
    func testBundleIsEachVolumesChunksThenTheEnd() {
        let sim = Simulation()
        let server = sim.node()
        server.volumes = Self.volumes
        server.bundles["root"] = Self.roots
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.volumeBundleRequest(requestID: 4, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.chunks.map(\.rootCID), Self.roots)
        XCTAssertTrue(peer.chunks.allSatisfy { $0.requestID == 4 })
        for root in Self.roots {
            XCTAssertEqual(
                peer.archive(requestID: 4, rootCID: root),
                VolumeArchive.encode(entries: servingSmallVolume(root), rootCID: root)?.data)
        }
        XCTAssertEqual(peer.bundleEnds, [4])
        guard case .volumeBundleEnd = peer.inbox.last else {
            return XCTFail("the end is not the last record")
        }
        XCTAssertEqual(peer.unavailable, [])
        // The bundle is listed once; each Volume is authorized and read as its own.
        XCTAssertEqual(server.bundleListings, ["root"])
        XCTAssertEqual(server.volumeAuthorizations, Self.roots)
        XCTAssertEqual(server.volumeReads, Self.roots)
        XCTAssertServingIdle(server)
    }

    // No bundle for the root, in each way a source can say so: an end with no Volume.
    func testNoBundleGivesAnEndWithNoVolume() {
        let sim = Simulation()
        let server = sim.node()
        server.volumes = Self.volumes
        // A listing that does not start with the root is no bundle of the root's.
        server.bundles["member-a"] = ["root", "member-a"]
        server.bundles["member-b"] = []
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        peer.send(.volumeBundleRequest(requestID: 2, rootCID: "member-a"))
        peer.send(.volumeBundleRequest(requestID: 3, rootCID: "member-b"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.bundleEnds, [1, 2, 3])
        XCTAssertEqual(peer.chunks, [])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertEqual(server.volumeAuthorizations, [])
        XCTAssertEqual(server.volumeReads, [])
        XCTAssertServingIdle(server)
    }

    // Without a content source there is nothing to list: an end, at once.
    func testBundleWithoutAContentSourceEndsAtOnce() {
        let sim = Simulation()
        let server = sim.node()
        sim.send(.command(.setContentSource(false)), to: server)
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        peer.send(.volumeRequest(requestID: 2, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.bundleEnds, [1])
        // A Volume it cannot serve is refused.
        XCTAssertEqual(peer.unavailable, [2])
        XCTAssertEqual(server.startedJobs.count, 0)
        XCTAssertServingIdle(server)
    }

    // Without the root's own Volume there is no bundle: the members are not sent.
    func testBundleWhoseRootCannotBeSentEndsWithNoVolume() {
        let sim = Simulation()
        let server = sim.node()
        server.volumes = Self.volumes
        server.volumes["root"] = nil
        server.bundles["root"] = Self.roots
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.bundleEnds, [1])
        XCTAssertEqual(peer.chunks, [])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertEqual(server.volumeReads, ["root"])
        XCTAssertServingIdle(server)
    }

    // A member the requester may not have is left out; the rest follow. A
    // root the requester may not have is no bundle.
    func testBundleLeavesOutAVolumeTheRequesterIsNotAuthorizedFor() {
        let sim = Simulation()
        let server = sim.node()
        server.volumes = Self.volumes
        server.bundles["root"] = Self.roots
        var denied = "member-a"
        server.authorize = { _, root in root != denied }
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.chunks.map(\.rootCID), ["root", "member-b"])
        XCTAssertEqual(peer.bundleEnds, [1])
        XCTAssertEqual(server.volumeReads, ["root", "member-b"])

        denied = "root"
        peer.send(.volumeBundleRequest(requestID: 2, rootCID: "root"))
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.chunks.filter { $0.requestID == 2 }, [])
        XCTAssertEqual(peer.bundleEnds, [1, 2])
        XCTAssertEqual(peer.unavailable, [])
        XCTAssertEqual(server.volumeReads, ["root", "member-b"])
        XCTAssertServingIdle(server)
    }

    // Between two Volumes a bundle holds no slot and no bytes, and queues
    // again as a new request of its peer would: it waits its turn by weight.
    func testBundleQueuesAgainForEachVolume() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600), maxConcurrentContentRequests: 1)
        server.volumes = Self.volumes
        for index in 0..<4 { server.volumes["other-\(index)"] = servingSmallVolume("other-\(index)") }
        server.bundles["root"] = Self.roots
        let bundler = ServingRawPeer(sim, to: server, index: 1)
        let other = ServingRawPeer(sim, to: server, index: 2)
        server.stallsStorage = true
        bundler.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        sim.runHoldingReads(server)
        for index in 0..<4 { other.send(.volumeRequest(requestID: UInt64(index + 1), rootCID: "other-\(index)")) }
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 4)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        // Each time it queues again the bundle starts one stride past the
        // virtual time, as a peer that begins to wait does, and so behind
        // the peer already waiting there: one Volume of its for two of theirs.
        XCTAssertEqual(
            server.volumeReads,
            ["root", "other-0", "other-1", "member-a", "other-2", "other-3", "member-b"])
        bundler.read()
        XCTAssertEqual(bundler.chunks.map(\.rootCID), Self.roots)
        XCTAssertEqual(bundler.bundleEnds, [1])
        XCTAssertServingIdle(server)
    }

    // A bundle waiting for its next slot is still a request in progress: a
    // duplicate of it is refused, and losing the session withdraws it.
    func testBundleBetweenVolumesIsWithdrawnWithItsSession() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(3_600), maxConcurrentContentRequests: 1)
        server.volumes = Self.volumes
        server.volumes["other"] = servingSmallVolume("other")
        server.bundles["root"] = Self.roots
        let bundler = ServingRawPeer(sim, to: server, index: 1)
        let other = ServingRawPeer(sim, to: server, index: 2)
        server.stallsStorage = true
        bundler.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        sim.runHoldingReads(server)
        other.send(.volumeRequest(requestID: 1, rootCID: "other"))
        sim.runHoldingReads(server)
        sim.releaseNextRead(server)
        // The bundle sent its root and waits behind the other peer's read.
        XCTAssertEqual(server.volumeReads, ["root", "other"])
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, worstCase)

        bundler.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        sim.runHoldingReads(server)
        bundler.read()
        XCTAssertEqual(bundler.unavailable, [1])
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 1)

        bundler.close()
        sim.runHoldingReads(server)
        XCTAssertEqual(server.core.diagnostics.servingRequestsWaiting, 0)
        sim.releaseStorage(server)
        sim.run(for: .seconds(1))
        XCTAssertEqual(server.volumeReads, ["root", "other"])
        XCTAssertEqual(server.bundleListings, ["root"])
        XCTAssertServingIdle(server)
    }

    // The end waits out a connection that is not taking records, like any reply.
    func testBundleEndWaitsForAWritableConnection() {
        let sim = Simulation()
        let server = sim.node(requestTimeout: .seconds(1))
        let peer = ServingRawPeer(sim, to: server, index: 1)
        peer.stopReading()
        peer.send(.volumeBundleRequest(requestID: 1, rootCID: "root"))
        // Nothing bounds an end that holds only its slot.
        sim.run(for: .seconds(5))
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertTrue(peer.read().isEmpty)
        peer.resumeReading()
        sim.run(for: .seconds(1))
        peer.read()
        XCTAssertEqual(peer.bundleEnds, [1])
        XCTAssertServingIdle(server)
    }
}
