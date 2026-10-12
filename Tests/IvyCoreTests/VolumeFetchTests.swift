import Foundation
import XCTest
@testable import IvyCore
@testable import IvySimulation
import Tally

/// The requesting side of Volume exchange: session fencing, ordered
/// assembly, the caller's boundary, the node's receive budget, and the
/// search order. Every scenario ends with nothing reserved.
final class VolumeFetchTests: XCTestCase {
    private let wholeVolume = MessageLimits.maxVolumeArchiveBytes
    private let anyEntryCount = Int(MessageLimits.maxVolumeEntryCount)

    private func requester(
        requestTimeout: Duration = .seconds(1),
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes
    ) -> (sim: Simulation, node: Simulation.Node, peer: FetchRawPeer) {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: requestTimeout, maxInFlightVolumeBytes: maxInFlightVolumeBytes)
        return (sim, node, FetchRawPeer(sim, to: node, index: 0))
    }

    /// Starts an exact-session fetch and returns it with its wire request ID.
    private func begin(
        _ sim: Simulation,
        _ node: Simulation.Node,
        from peer: FetchRawPeer,
        root: String = "root",
        maximumArchiveBytes: Int = MessageLimits.maxVolumeArchiveBytes,
        maximumEntries: Int = Int(MessageLimits.maxVolumeEntryCount),
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (fetch: RequestID, requestID: UInt64) {
        let fetch = sim.request(
            .fetchVolumeFrom(
                peer.authenticated,
                rootCID: root,
                maximumArchiveBytes: maximumArchiveBytes,
                maximumEntries: maximumEntries),
            on: node)
        let wire = peer.takeVolumeRequest()
        XCTAssertEqual(wire?.rootCID, root, file: file, line: line)
        XCTAssertEqual(wire?.bundle, false, file: file, line: line)
        return (fetch, wire?.requestID ?? 0)
    }

    private func archive(_ bytes: Int = 128) -> VolumeArchive {
        VolumeArchive.encode(
            entries: [ContentEntry(cid: "root", data: Data(repeating: 0xaa, count: bytes))],
            rootCID: "root")!
    }

    private func chunk(
        _ requestID: UInt64,
        root: String = "root",
        index: UInt16,
        count: UInt16,
        totalEntries: UInt16 = 1,
        totalBytes: Int,
        payload: Data
    ) -> Message {
        .volumeChunk(
            requestID: requestID,
            rootCID: root,
            index: index,
            count: count,
            totalEntries: totalEntries,
            totalBytes: UInt64(totalBytes),
            payload: payload)
    }

    /// Hands the node a chunk the codec would not encode, as its session
    /// handler would, to reach the checks the handler makes for itself.
    private func deliverUnencodable(
        _ sim: Simulation,
        _ node: Simulation.Node,
        from peer: FetchRawPeer,
        _ requestID: UInt64,
        root: String = "root",
        index: UInt16 = 0,
        count: UInt16 = 1,
        totalEntries: UInt16 = 1,
        totalBytes: Int,
        payload: Data
    ) {
        node.core.handleVolumeChunk(
            requestID: requestID,
            rootCID: root,
            index: index,
            count: count,
            totalEntries: totalEntries,
            totalBytes: UInt64(totalBytes),
            payload: payload,
            from: peer.peer,
            sessionID: peer.sessionID,
            relayed: false)
        // Collects the effects of the call above.
        sim.send(.tick, to: node)
    }

    // MARK: - The node's own source

    /// A complete Volume is fetched as one boundary.
    func testCompleteLocalVolume() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.volumes["root"] = [
            ContentEntry(cid: "child", data: Data("child".utf8)),
            ContentEntry(cid: "root", data: Data("root".utf8)),
        ]
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let response = sim.await(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: node)?.volume

        XCTAssertEqual(response, AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": Data("root".utf8), "child": Data("child".utf8)],
            servedBy: nil))
        XCTAssertNil(peer.takeVolumeRequest())
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(node.core.diagnostics.reservedServingVolumeBytes, 0)
    }

    func testCancelledLocalVolumeReadStaysCountedUntilItsJobFinishes() {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        node.volumes["root"] = [ContentEntry(cid: "root", data: Data("root".utf8))]
        node.stallsStorage = true

        let fetch = sim.request(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: node)
        XCTAssertEqual(node.volumeReadsStarted, ["root"])
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(node.core.diagnostics.reservedServingVolumeBytes, wholeVolume)

        sim.cancel(fetch, on: node)
        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        XCTAssertEqual(node.cancelledJobs, node.startedJobs.map(\.id))
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 1)
        XCTAssertEqual(node.core.diagnostics.reservedServingVolumeBytes, wholeVolume)

        sim.releaseStorage(node)
        sim.settleDue()
        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        XCTAssertEqual(node.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(node.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(node.core.diagnostics.jobsOutstanding, 0)
    }

    // MARK: - Exact sessions

    /// An advertised Volume is fenced to the exact authenticated session.
    func testExactVolumeSessionIsFenced() {
        let (sim, node, peer) = requester()
        let oldPeer = peer.authenticated
        peer.replaceSession()

        let stale = sim.request(
            .fetchVolumeFrom(oldPeer, rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: node)
        XCTAssertEqual(sim.result(of: stale, on: node), .volume(.empty))
        XCTAssertNil(peer.takeVolumeRequest())
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)

        let (fetch, requestID) = begin(sim, node, from: peer)
        let entries = [
            ContentEntry(cid: "root", data: Data("root".utf8)),
            ContentEntry(cid: "child", data: Data("child".utf8)),
        ]
        let whole = VolumeArchive.encode(entries: entries, rootCID: "root")!

        node.core.handleVolumeChunk(
            requestID: requestID,
            rootCID: "root",
            index: 0,
            count: 1,
            totalEntries: UInt16(whole.entries.count),
            totalBytes: UInt64(whole.data.count),
            payload: whole.data,
            from: peer.peer,
            sessionID: oldPeer.sessionID,
            relayed: false)
        XCTAssertNotNil(node.core.pendingVolumeRequests[requestID])
        XCTAssertNil(sim.result(of: fetch, on: node))
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, 0)

        peer.sendVolume(requestID: requestID, root: "root", entries: entries)
        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": Data("root".utf8), "child": Data("child".utf8)],
            servedBy: peer.peer)))
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
    }

    func testReplacementSessionCannotFinishAPartialVolume() {
        let (sim, node, peer) = requester()
        let whole = archive()
        let split = whole.data.count / 2

        let (fetch, requestID) = begin(sim, node, from: peer)
        peer.send(chunk(
            requestID, index: 0, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[..<split])))
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, split)

        peer.replaceSession()
        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)

        peer.send(chunk(
            requestID, index: 1, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[split...])))
        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    /// Solicited content replies are accepted only on the exact session.
    func testSolicitedRepliesAreAcceptedOnExactSession() {
        let (sim, node, peer) = requester()
        let entries = [ContentEntry(cid: "root", data: Data("root".utf8))]
        let whole = VolumeArchive.encode(entries: entries, rootCID: "root")!

        let (volumeFetch, volumeRequestID) = begin(sim, node, from: peer)
        // A session that is not the one asked.
        node.core.handleVolumeChunk(
            requestID: volumeRequestID,
            rootCID: "root",
            index: 0,
            count: 1,
            totalEntries: 1,
            totalBytes: UInt64(whole.data.count),
            payload: whole.data,
            from: peer.peer,
            sessionID: nil,
            relayed: false)
        XCTAssertNotNil(node.core.pendingVolumeRequests[volumeRequestID])
        // A request that was never made.
        peer.sendVolume(requestID: volumeRequestID &+ 1_000, root: "root", entries: entries)
        XCTAssertNotNil(node.core.pendingVolumeRequests[volumeRequestID])
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)

        peer.sendVolume(requestID: volumeRequestID, root: "root", entries: entries)
        XCTAssertEqual(sim.result(of: volumeFetch, on: node), .volume(AttributedVolumeResponse(
            rootCID: "root", entries: ["root": Data("root".utf8)], servedBy: peer.peer)))

        let (unavailableFetch, unavailableRequestID) = begin(sim, node, from: peer, root: "missing")
        peer.send(.contentUnavailable(requestID: unavailableRequestID))
        XCTAssertEqual(sim.result(of: unavailableFetch, on: node), .volume(.empty))
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)

        let contentFetch = sim.request(
            .fetchContentFrom(peer.authenticated, rootCID: "root", cids: []), on: node)
        let contentRequestID = peer.takeContentRequest()!.requestID
        peer.send(.contentResponse(requestID: contentRequestID, entries: entries))
        XCTAssertEqual(sim.result(of: contentFetch, on: node), .content(AttributedContentResponse(
            entries: ["root": Data("root".utf8)], servedBy: peer.peer)))

        let (malformedFetch, malformedRequestID) = begin(sim, node, from: peer, root: "malformed")
        peer.send(chunk(
            malformedRequestID, root: "wrong-root", index: 0, count: 1, totalBytes: 1, payload: Data([0])))
        XCTAssertEqual(sim.result(of: malformedFetch, on: node), .volume(.empty))
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 1)

        let (oversizedFetch, oversizedRequestID) = begin(sim, node, from: peer, root: "oversized")
        deliverUnencodable(
            sim, node, from: peer, oversizedRequestID, root: "oversized",
            totalBytes: MessageLimits.maxVolumeArchiveBytes + 1, payload: Data([0]))
        XCTAssertEqual(sim.result(of: oversizedFetch, on: node), .volume(.empty))
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 2)
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    // MARK: - The caller's boundary

    /// Caller Volume limits reject advertised excess before allocation.
    func testCallerVolumeLimitsRejectBeforeAllocation() {
        let (sim, node, peer) = requester()

        let (memberLimited, memberRequestID) = begin(
            sim, node, from: peer, maximumArchiveBytes: 1_024, maximumEntries: 1)
        peer.sendVolume(requestID: memberRequestID, root: "root", entries: [
            ContentEntry(cid: "root", data: Data("root".utf8)),
            ContentEntry(cid: "padding", data: Data("padding".utf8)),
        ])
        XCTAssertEqual(sim.result(of: memberLimited, on: node)?.volume?.failure, .callerBoundaryExceeded)
        XCTAssertEqual(sim.result(of: memberLimited, on: node)?.volume?.entries, [:])
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)

        let entry = ContentEntry(cid: "root", data: Data(repeating: 0xaa, count: 128))
        let whole = VolumeArchive.encode(entries: [entry], rootCID: "root")!
        let (byteLimited, byteRequestID) = begin(
            sim, node, from: peer, maximumArchiveBytes: whole.data.count - 1, maximumEntries: 1)
        peer.sendVolume(requestID: byteRequestID, root: "root", entries: [entry])
        XCTAssertEqual(sim.result(of: byteLimited, on: node)?.volume?.failure, .callerBoundaryExceeded)
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)

        let (exactBound, exactRequestID) = begin(
            sim, node, from: peer, maximumArchiveBytes: whole.data.count, maximumEntries: 1)
        peer.sendVolume(requestID: exactRequestID, root: "root", entries: [entry])
        XCTAssertEqual(sim.result(of: exactBound, on: node), .volume(AttributedVolumeResponse(
            rootCID: "root", entries: ["root": entry.data], servedBy: peer.peer)))

        let (inconsistent, inconsistentRequestID) = begin(
            sim, node, from: peer, maximumArchiveBytes: whole.data.count, maximumEntries: 1)
        let split = whole.data.count / 2
        peer.send(chunk(
            inconsistentRequestID, index: 0, count: 2, totalBytes: whole.data.count,
            payload: Data(whole.data[..<split])))
        peer.send(chunk(
            inconsistentRequestID, index: 1, count: 2, totalBytes: whole.data.count + 1,
            payload: Data(whole.data[split...])))
        XCTAssertEqual(sim.result(of: inconsistent, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 1)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    func testInvalidCallerBoundaryCompletesEmptyWithoutAsking() {
        let (sim, node, peer) = requester()
        for (bytes, entries) in [(0, 1), (1, 0), (-1, 1)] {
            let exact = sim.request(
                .fetchVolumeFrom(
                    peer.authenticated, rootCID: "root", maximumArchiveBytes: bytes, maximumEntries: entries),
                on: node)
            let discovered = sim.request(
                .fetchVolume(rootCID: "root", maximumArchiveBytes: bytes, maximumEntries: entries), on: node)
            XCTAssertEqual(sim.result(of: exact, on: node), .volume(.empty))
            XCTAssertEqual(sim.result(of: discovered, on: node), .volume(.empty))
        }
        XCTAssertNil(peer.takeVolumeRequest())
    }

    /// Volume archive accepts the hard byte cap and rejects one byte over.
    func testVolumeArchiveByteCap() {
        let rootCID = "root"
        let archiveOverhead = 2 + 2 + rootCID.utf8.count + 4
        let exact = ContentEntry(
            cid: rootCID,
            data: Data(repeating: 0xaa, count: MessageLimits.maxVolumeArchiveBytes - archiveOverhead))
        XCTAssertEqual(
            VolumeArchive.encode(entries: [exact], rootCID: rootCID)?.data.count,
            MessageLimits.maxVolumeArchiveBytes)

        let oversized = ContentEntry(cid: rootCID, data: exact.data + Data([0xbb]))
        XCTAssertNil(VolumeArchive.encode(entries: [oversized], rootCID: rootCID))
    }

    // MARK: - Assembly

    /// Volume chunks reject gaps and duplicates without leaking bytes.
    func testVolumeChunkSequenceIsStrict() {
        let (sim, node, peer) = requester()
        let whole = archive()
        let split = whole.data.count / 2
        let first = Data(whole.data[..<split])

        let (outOfOrder, outOfOrderID) = begin(sim, node, from: peer)
        peer.send(chunk(
            outOfOrderID, index: 1, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[split...])))
        XCTAssertEqual(sim.result(of: outOfOrder, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 1)

        let (duplicate, duplicateID) = begin(sim, node, from: peer)
        peer.send(chunk(duplicateID, index: 0, count: 2, totalBytes: whole.data.count, payload: first))
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, first.count)
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, whole.data.count)
        XCTAssertNil(sim.result(of: duplicate, on: node))
        peer.send(chunk(duplicateID, index: 0, count: 2, totalBytes: whole.data.count, payload: first))
        XCTAssertEqual(sim.result(of: duplicate, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 2)

        let third = whole.data.count / 3
        let (gap, gapID) = begin(sim, node, from: peer)
        peer.send(chunk(
            gapID, index: 0, count: 3, totalBytes: whole.data.count, payload: Data(whole.data[..<third])))
        peer.send(chunk(
            gapID, index: 2, count: 3, totalBytes: whole.data.count, payload: Data(whole.data[(2 * third)...])))
        XCTAssertEqual(sim.result(of: gap, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 3)

        // The same peer, behaving, is still served from.
        let (ordered, orderedID) = begin(sim, node, from: peer)
        peer.send(chunk(orderedID, index: 0, count: 2, totalBytes: whole.data.count, payload: first))
        XCTAssertNil(sim.result(of: ordered, on: node))
        peer.send(chunk(
            orderedID, index: 1, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[split...])))
        XCTAssertEqual(sim.result(of: ordered, on: node)?.volume?.entries, ["root": whole.entries[0].data])
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 3)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    func testConflictingStreamMetadataDiscardsTheAttempt() {
        let (sim, node, peer) = requester()
        let whole = archive()
        let split = whole.data.count / 2
        let first = Data(whole.data[..<split])
        let rest = Data(whole.data[split...])
        let total = whole.data.count
        let conflicts: [(UInt64) -> Message] = [
            { self.chunk($0, root: "other", index: 1, count: 2, totalBytes: total, payload: rest) },
            { self.chunk($0, index: 1, count: 3, totalBytes: total, payload: rest) },
            { self.chunk($0, index: 1, count: 2, totalEntries: 2, totalBytes: total, payload: rest) },
            { self.chunk($0, index: 1, count: 2, totalBytes: total + 1, payload: rest) },
            // More bytes than the archive was declared to hold.
            { self.chunk($0, index: 1, count: 2, totalBytes: total, payload: rest + Data([0])) },
            // Every chunk arrived, short of the declared size.
            { self.chunk($0, index: 1, count: 2, totalBytes: total, payload: Data(rest.dropLast())) },
        ]

        for (index, conflict) in conflicts.enumerated() {
            let (fetch, requestID) = begin(sim, node, from: peer)
            peer.send(chunk(requestID, index: 0, count: 2, totalBytes: total, payload: first))
            XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, total)
            peer.send(conflict(requestID))
            XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty), "conflict \(index)")
            assertHoldsNoVolumeBytes(node)
            XCTAssertEqual(node.ledger.violations(of: peer.peer), index + 1, "conflict \(index)")
        }
    }

    func testMalformedArchiveDiscardsTheAttempt() {
        let (sim, node, peer) = requester()
        let other = VolumeArchive.encode(
            entries: [ContentEntry(cid: "other", data: Data("other".utf8))], rootCID: "other")!
        let whole = archive()
        let malformed: [(UInt64) -> Message] = [
            // Not an archive at all.
            { self.chunk($0, index: 0, count: 1, totalBytes: 16, payload: Data(repeating: 0xff, count: 16)) },
            // A well-formed archive that does not hold the requested root.
            { self.chunk($0, index: 0, count: 1, totalBytes: other.data.count, payload: other.data) },
            // An entry count the archive does not bear out.
            { self.chunk($0, index: 0, count: 1, totalEntries: 2, totalBytes: whole.data.count, payload: whole.data) },
        ]
        var violations = 0
        for (index, message) in malformed.enumerated() {
            let (fetch, requestID) = begin(sim, node, from: peer)
            peer.send(message(requestID))
            violations += 1
            XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty), "malformed \(index)")
            assertHoldsNoVolumeBytes(node)
            XCTAssertEqual(node.ledger.violations(of: peer.peer), violations, "malformed \(index)")
        }

        // Shapes the codec itself refuses: nothing in a chunk, no chunks, no
        // entries, no bytes, an index past the end, too many chunks, too
        // many bytes.
        let total = whole.data.count
        let unencodable: [(UInt64) -> Void] = [
            { self.deliverUnencodable(sim, node, from: peer, $0, totalBytes: total, payload: Data()) },
            { self.deliverUnencodable(sim, node, from: peer, $0, count: 0, totalBytes: total, payload: whole.data) },
            { self.deliverUnencodable(
                sim, node, from: peer, $0, totalEntries: 0, totalBytes: total, payload: whole.data) },
            { self.deliverUnencodable(sim, node, from: peer, $0, totalBytes: 0, payload: whole.data) },
            { self.deliverUnencodable(
                sim, node, from: peer, $0, index: 1, count: 1, totalBytes: total, payload: whole.data) },
            { self.deliverUnencodable(
                sim, node, from: peer, $0, count: MessageLimits.maxVolumeChunkCount + 1,
                totalBytes: total, payload: Data([0])) },
            { self.deliverUnencodable(
                sim, node, from: peer, $0, totalBytes: MessageLimits.maxVolumeArchiveBytes + 1,
                payload: Data([0])) },
        ]
        for (index, deliver) in unencodable.enumerated() {
            let (fetch, requestID) = begin(sim, node, from: peer)
            deliver(requestID)
            violations += 1
            XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty), "unencodable \(index)")
            assertHoldsNoVolumeBytes(node)
            XCTAssertEqual(node.ledger.violations(of: peer.peer), violations, "unencodable \(index)")
        }
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    /// On the wire, a chunk the codec refuses does not decode: the session
    /// that sent it ends, and the fetch with it.
    func testUndecodableChunkEndsTheSessionAndTheFetch() {
        let (sim, node, peer) = requester()
        let whole = archive()
        let split = whole.data.count / 2

        let (fetch, requestID) = begin(sim, node, from: peer)
        peer.send(chunk(
            requestID, index: 0, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[..<split])))
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, whole.data.count)

        // A volumeChunk declaring zero chunks, encoded by hand.
        var payload = Data([28])
        payload.append(contentsOf: withUnsafeBytes(of: requestID.bigEndian) { Array($0) })
        payload.append(contentsOf: [0, 4])
        payload.append(Data("root".utf8))
        payload.append(contentsOf: [0, 1, 0, 0, 0, 1])
        payload.append(contentsOf: withUnsafeBytes(of: UInt64(whole.data.count).bigEndian) { Array($0) })
        payload.append(contentsOf: [0, 0, 0, 1, 0xaa])
        XCTAssertNil(Message.deserialize(payload))
        XCTAssertFalse(Message.hasUnknownTag(payload))
        peer.sendPayload(payload)

        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
        XCTAssertTrue(node.core.connectedPeers.isEmpty)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 1)
    }

    /// A first chunk that claims more chunks but carries every byte is
    /// rejected and its bytes released.
    func testOverfullFirstChunkReleasesItsBytes() {
        let (sim, node, peer) = requester()

        let (rejected, rejectedID) = begin(sim, node, from: peer)
        peer.sendVolume(requestID: rejectedID, root: "root", count: 2)
        XCTAssertEqual(sim.result(of: rejected, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 1)

        let (served, servedID) = begin(sim, node, from: peer)
        peer.sendVolume(requestID: servedID, root: "root")
        XCTAssertEqual(sim.result(of: served, on: node)?.volume?.entries, ["root": Data("root".utf8)])
        assertHoldsNoVolumeBytes(node)
    }

    /// Cancelling a partial Volume releases its assembly immediately.
    func testPartialVolumeCancellation() {
        let (sim, node, peer) = requester()
        let whole = archive()
        let split = whole.data.count / 2

        let (fetch, requestID) = begin(sim, node, from: peer)
        peer.send(chunk(
            requestID, index: 0, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[..<split])))
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, split)
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, whole.data.count)

        sim.cancel(fetch, on: node)

        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
        XCTAssertTrue(node.core.volumeFetches.isEmpty)
        // The rest of the Volume arrives for nobody.
        peer.send(chunk(
            requestID, index: 1, count: 2, totalBytes: whole.data.count, payload: Data(whole.data[split...])))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
    }

    /// Cancelling before a Volume request is answered leaves no pending request.
    func testVolumeCancellationBeforeInsertion() {
        let (sim, node, peer) = requester()
        let deadlines = node.core.diagnostics.deadlines
        for _ in 0..<32 {
            let fetch = sim.request(
                .fetchVolumeFrom(
                    peer.authenticated, rootCID: "root", maximumArchiveBytes: wholeVolume,
                    maximumEntries: anyEntryCount),
                on: node)
            sim.cancel(fetch, on: node)
            XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        }
        XCTAssertTrue(node.core.pendingVolumeRequests.isEmpty)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
        XCTAssertEqual(node.core.diagnostics.pendingRequests, 0)
        XCTAssertEqual(node.core.diagnostics.deadlines, deadlines)
    }

    /// Partial Volume timeout and stop release reservations.
    func testPartialVolumeTimeoutAndStop() {
        let (sim, node, peer) = requester(requestTimeout: .seconds(1))
        let whole = archive()
        let split = whole.data.count / 2

        func beginPartialFetch() -> (RequestID, UInt64) {
            let (fetch, requestID) = begin(sim, node, from: peer)
            peer.send(chunk(
                requestID, index: 0, count: 2, totalBytes: whole.data.count,
                payload: Data(whole.data[..<split])))
            XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, split)
            XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, whole.data.count)
            return (fetch, requestID)
        }

        let (timedOut, _) = beginPartialFetch()
        let started = sim.now
        sim.run(until: { sim.result(of: timedOut, on: node) != nil })
        XCTAssertEqual(sim.result(of: timedOut, on: node), .volume(.empty))
        XCTAssertEqual(sim.now - started, .seconds(1))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)

        let (stopped, requestID) = beginPartialFetch()
        sim.stop(node)
        XCTAssertEqual(sim.result(of: stopped, on: node), .volume(.empty))
        assertHoldsNoVolumeBytes(node)
        node.core.handleVolumeChunk(
            requestID: requestID,
            rootCID: "root",
            index: 1,
            count: 2,
            totalEntries: 1,
            totalBytes: UInt64(whole.data.count),
            payload: Data(whole.data[split...]),
            from: peer.peer,
            sessionID: peer.sessionID,
            relayed: false)
        assertHoldsNoVolumeBytes(node)
    }

    /// Competing providers assemble independently and resolve atomically.
    func testCompetingVolumeProvidersAreIsolated() {
        let sim = Simulation()
        let node = sim.fetchNode()
        let first = FetchRawPeer(sim, to: node, index: 0)
        let second = FetchRawPeer(sim, to: node, index: 1)
        let firstEntries = [ContentEntry(cid: "root", data: Data("first".utf8))]
        let secondEntries = [ContentEntry(cid: "root", data: Data("second".utf8))]
        let firstArchive = VolumeArchive.encode(entries: firstEntries, rootCID: "root")!
        let secondArchive = VolumeArchive.encode(entries: secondEntries, rootCID: "root")!
        let firstSplit = firstArchive.data.count / 2

        let (firstFetch, firstID) = begin(sim, node, from: first)
        let (secondFetch, secondID) = begin(sim, node, from: second)
        first.send(chunk(
            firstID, index: 0, count: 2, totalBytes: firstArchive.data.count,
            payload: Data(firstArchive.data[..<firstSplit])))
        // One provider's chunks do not continue another's stream.
        second.send(chunk(
            firstID, index: 1, count: 2, totalBytes: firstArchive.data.count,
            payload: Data(firstArchive.data[firstSplit...])))
        XCTAssertNil(sim.result(of: firstFetch, on: node))
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, firstSplit)

        second.sendVolume(requestID: secondID, root: "root", entries: secondEntries)
        XCTAssertEqual(sim.result(of: secondFetch, on: node), .volume(AttributedVolumeResponse(
            rootCID: "root", entries: ["root": Data("second".utf8)], servedBy: second.peer)))
        XCTAssertNil(sim.result(of: firstFetch, on: node))
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, firstSplit)
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, firstArchive.data.count)
        XCTAssertEqual(secondArchive.entries.count, 1)

        first.send(chunk(
            firstID, index: 1, count: 2, totalBytes: firstArchive.data.count,
            payload: Data(firstArchive.data[firstSplit...])))
        XCTAssertEqual(sim.result(of: firstFetch, on: node), .volume(AttributedVolumeResponse(
            rootCID: "root", entries: ["root": Data("first".utf8)], servedBy: first.peer)))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: first.peer), 0)
        XCTAssertEqual(node.ledger.violations(of: second.peer), 0)
    }

    // MARK: - The receive budget

    /// Promised Volume sizes share one aggregate receive reservation.
    func testReceivingVolumeReservationCap() {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peers = (0..<3).map { FetchRawPeer(sim, to: node, index: $0) }

        var fetches: [RequestID] = []
        for peer in peers {
            let (fetch, requestID) = begin(sim, node, from: peer)
            fetches.append(fetch)
            peer.send(chunk(
                requestID, index: 0, count: 2, totalBytes: MessageLimits.maxVolumeArchiveBytes,
                payload: Data([0])))
        }

        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, IvyConfig.defaultMaxInFlightVolumeBytes)
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, 2)
        XCTAssertEqual(node.core.pendingVolumeRequests.count, 2)
        XCTAssertNil(sim.result(of: fetches[0], on: node))
        XCTAssertNil(sim.result(of: fetches[1], on: node))
        XCTAssertEqual(sim.result(of: fetches[2], on: node)?.volume?.failure, .localCapacityUnavailable)
        XCTAssertEqual(sim.result(of: fetches[2], on: node)?.volume?.entries, [:])
        // The node's own capacity is nobody's violation.
        for peer in peers { XCTAssertEqual(node.ledger.violations(of: peer.peer), 0) }
        XCTAssertEqual(Set(node.core.connectedPeers), Set(peers.map(\.peer)))

        sim.cancel(fetches[0], on: node)
        XCTAssertEqual(node.core.diagnostics.reservedVolumeBytes, MessageLimits.maxVolumeArchiveBytes)
        XCTAssertEqual(node.core.diagnostics.inFlightVolumeBytes, 1)
        sim.cancel(fetches[1], on: node)
        assertHoldsNoVolumeBytes(node)
    }

    func testInFlightVolumeBudgetGivesLocalCapacityUnavailable() {
        let whole = archive(128)
        let (sim, node, peer) = requester(maxInFlightVolumeBytes: whole.data.count - 1)

        let (tooLarge, tooLargeID) = begin(sim, node, from: peer)
        peer.sendVolume(requestID: tooLargeID, root: "root", entries: whole.entries)
        XCTAssertEqual(sim.result(of: tooLarge, on: node), .volume(.localCapacityUnavailable))
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)

        // A Volume within the budget is unaffected.
        let small = [ContentEntry(cid: "root", data: Data("root".utf8))]
        let (fits, fitsID) = begin(sim, node, from: peer)
        peer.sendVolume(requestID: fitsID, root: "root", entries: small)
        XCTAssertEqual(sim.result(of: fits, on: node)?.volume?.entries, ["root": Data("root".utf8)])
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(node.core.connectedPeers, [peer.peer])
    }

    func testPendingRequestCapGivesLocalCapacityUnavailable() {
        let sim = Simulation()
        let node = sim.fetchNode(maxPendingRequests: 1)
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let (held, heldID) = begin(sim, node, from: peer, root: "root-a")
        let refused = sim.request(
            .fetchVolumeFrom(
                peer.authenticated, rootCID: "root-b", maximumArchiveBytes: wholeVolume,
                maximumEntries: anyEntryCount),
            on: node)

        XCTAssertEqual(sim.result(of: refused, on: node), .volume(.localCapacityUnavailable))
        XCTAssertNil(peer.takeVolumeRequest())
        XCTAssertEqual(node.core.outstandingVolumeRequests[peer.peer], 1)

        peer.sendVolume(requestID: heldID, root: "root-a")
        XCTAssertEqual(sim.result(of: held, on: node)?.volume?.rootCID, "root-a")
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
    }

    // MARK: - The search order

    /// A Volume fetch asks the node's own source, then known providers, then
    /// the peers already connected, then fresh discovery.
    func testSearchAsksLocalSourceThenKnownProvidersThenConnectedPeersThenDiscovery() throws {
        let sim = Simulation()
        let node = sim.fetchNode(contentSource: true)
        let provider = FetchRawPeer(sim, to: node, index: 0)
        let router = FetchRawPeer(sim, to: node, index: 1, advertises: true)
        let bystander = FetchRawPeer(sim, to: node, index: 2)
        provider.send(.announceProvider(rootCID: "root", expiresAt: sim.unixSeconds + 60))
        func nobodyAsked() -> Bool {
            [provider, router, bystander].allSatisfy { $0.takeMessages().isEmpty }
        }

        let fetch = sim.request(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: node)

        // The node's own source, and nothing on the wire while it reads.
        XCTAssertEqual(node.volumeReadsStarted, ["root"])
        XCTAssertTrue(nobodyAsked())
        sim.settleDue()

        // The provider that announced the root.
        let known = try XCTUnwrap(provider.takeVolumeRequest()).requestID
        XCTAssertTrue(nobodyAsked())
        provider.send(.contentUnavailable(requestID: known))

        // The other connected peers, one at a time, before any lookup.
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)
        var connected = [router, bystander]
        let firstIndex = try XCTUnwrap(connected.firstIndex { $0.takeVolumeRequestID() != nil })
        let first = connected.remove(at: firstIndex)
        let second = connected[0]
        XCTAssertNil(second.takeVolumeRequest())
        XCTAssertNil(provider.takeVolumeRequest())
        first.send(.contentUnavailable(requestID: first.lastVolumeRequestID))
        XCTAssertNotNil(second.takeVolumeRequestID())
        XCTAssertEqual(node.core.freshProviderQueryCount, 0)
        XCTAssertNil(router.takeProviderQuery())
        second.send(.contentUnavailable(requestID: second.lastVolumeRequestID))

        // Only then the network.
        XCTAssertEqual(node.core.freshProviderQueryCount, 1)
        let query = try XCTUnwrap(router.takeProviderQuery())
        XCTAssertNil(sim.result(of: fetch, on: node))
        router.send(.providers(rootCID: "root", requestID: query.requestID, records: []))

        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(.empty))
        XCTAssertTrue(nobodyAsked())
        assertHoldsNoVolumeBytes(node)
        XCTAssertTrue(node.core.outstandingVolumeRequests.isEmpty)
        XCTAssertTrue(node.core.volumeFetches.isEmpty)
    }

    /// `requestTimeout` bounds each request of a Volume fetch, never the fetch.
    func testVolumeFetchHasNoOverallDeadline() throws {
        let sim = Simulation()
        let node = sim.fetchNode(requestTimeout: .seconds(2))
        let peers = (0..<3).map { FetchRawPeer(sim, to: node, index: $0) }
        let started = sim.now

        let fetch = sim.request(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: node)

        // Two peers in turn let their request time out.
        var silent: [FetchRawPeer] = []
        for _ in 0..<2 {
            let asked = try XCTUnwrap(peers.first { $0.takeVolumeRequestID() != nil })
            silent.append(asked)
            sim.run(for: .seconds(2))
            XCTAssertNil(sim.result(of: fetch, on: node))
        }
        XCTAssertEqual(sim.now - started, .seconds(4))
        XCTAssertEqual(silent.map { node.core.volumeTimeoutStreaks[$0.peer] }, [1, 1])

        // The third answers long after `requestTimeout` from the fetch's start.
        let last = try XCTUnwrap(peers.first { $0.takeVolumeRequestID() != nil })
        XCTAssertFalse(silent.contains { $0 === last })
        sim.run(for: .seconds(1))
        last.sendVolume(requestID: last.lastVolumeRequestID, root: "root")

        XCTAssertEqual(sim.result(of: fetch, on: node), .volume(AttributedVolumeResponse(
            rootCID: "root", entries: ["root": Data("root".utf8)], servedBy: last.peer)))
        XCTAssertEqual(sim.now - started, .seconds(5))
        assertHoldsNoVolumeBytes(node)
        for peer in peers { XCTAssertEqual(node.ledger.violations(of: peer.peer), 0) }
    }

    /// One provider's violation discards only its attempt: the fetch goes on
    /// to the next peer.
    func testViolationDiscardsOnlyThatProvidersAttempt() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peers = (0..<2).map { FetchRawPeer(sim, to: node, index: $0) }

        let fetch = sim.request(
            .fetchVolume(rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: node)
        let bad = try XCTUnwrap(peers.first { $0.takeVolumeRequestID() != nil })
        let good = try XCTUnwrap(peers.first { $0 !== bad })
        XCTAssertNil(good.takeVolumeRequest())

        bad.send(chunk(
            bad.lastVolumeRequestID, index: 0, count: 1, totalBytes: 8, payload: Data(repeating: 0xff, count: 8)))
        XCTAssertNil(sim.result(of: fetch, on: node))
        XCTAssertEqual(node.ledger.violations(of: bad.peer), 1)
        assertHoldsNoVolumeBytes(node, pending: 1)

        XCTAssertNotNil(good.takeVolumeRequestID())
        good.sendVolume(requestID: good.lastVolumeRequestID, root: "root")

        XCTAssertEqual(sim.result(of: fetch, on: node)?.volume?.servedBy, good.peer)
        XCTAssertEqual(node.ledger.violations(of: good.peer), 0)
        assertHoldsNoVolumeBytes(node)
        XCTAssertEqual(Set(node.core.connectedPeers), Set(peers.map(\.peer)))
    }

    /// A caller boundary one peer exceeds still reaches the caller when
    /// nobody else has the Volume.
    func testCallerBoundaryFailureSurvivesTheRestOfTheSearch() throws {
        let sim = Simulation()
        let node = sim.fetchNode()
        let peer = FetchRawPeer(sim, to: node, index: 0)

        let fetch = sim.request(.fetchVolume(rootCID: "root", maximumArchiveBytes: 8, maximumEntries: 1), on: node)
        XCTAssertNotNil(peer.takeVolumeRequestID())
        peer.sendVolume(requestID: peer.lastVolumeRequestID, root: "root")

        XCTAssertEqual(sim.result(of: fetch, on: node)?.volume?.failure, .callerBoundaryExceeded)
        XCTAssertEqual(node.ledger.violations(of: peer.peer), 0)
        assertHoldsNoVolumeBytes(node)
    }

    /// A complete Volume larger than one frame crosses an authenticated session.
    func testMultiFrameVolume() {
        let sim = Simulation()
        let server = sim.node()
        let client = sim.node()
        let rootBytes = Data(repeating: 0xa5, count: Int(IvyConfig.defaultProtocolMaxFrameSize) + 1)
        let childBytes = Data("child".utf8)
        server.volumes["root"] = [
            ContentEntry(cid: "root", data: rootBytes),
            ContentEntry(cid: "child", data: childBytes),
        ]
        sim.connect(client, server)
        let serverPeer = sim.session(client, to: server)

        let response = sim.await(
            .fetchVolumeFrom(
                serverPeer, rootCID: "root", maximumArchiveBytes: wholeVolume, maximumEntries: anyEntryCount),
            on: client)?.volume

        XCTAssertEqual(response, AttributedVolumeResponse(
            rootCID: "root",
            entries: ["root": rootBytes, "child": childBytes],
            servedBy: serverPeer.id))
        sim.run(for: .seconds(1))
        assertHoldsNoVolumeBytes(client)
        XCTAssertEqual(server.core.diagnostics.reservedServingVolumeBytes, 0)
        XCTAssertEqual(server.core.diagnostics.servingSlotsHeld, 0)
        XCTAssertEqual(client.core.diagnostics.inboundBytesUsed, 0)
    }
}
