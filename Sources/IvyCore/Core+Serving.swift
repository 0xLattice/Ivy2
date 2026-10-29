#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

// `log2`, which Foundation would otherwise re-export.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// One Volume or bundle request a peer made on one session.
struct InboundContentRequest: Hashable, Sendable {
    let peer: PeerID
    let link: LinkID
    let requestID: UInt64
}

/// A peer with requests waiting for a serving slot.
struct WaitingServingPeer: Sendable {
    var pass: Double
    /// Waiting tickets in arrival order, from `head`; granted ones before it
    /// are dropped in batches so a deep queue is not shifted on every grant.
    private var tickets: [(request: InboundContentRequest, arrival: UInt64)] = []
    private var head = 0

    init(pass: Double) {
        self.pass = pass
    }

    var first: (request: InboundContentRequest, arrival: UInt64)? {
        head < tickets.count ? tickets[head] : nil
    }

    var isEmpty: Bool { head == tickets.count }
    var count: Int { tickets.count - head }

    mutating func append(_ request: InboundContentRequest, arrival: UInt64) {
        tickets.append((request, arrival))
    }

    mutating func remove(_ request: InboundContentRequest) {
        if first?.request == request {
            head += 1
            if head >= 64, head * 2 >= tickets.count {
                tickets.removeFirst(head)
                head = 0
            }
        } else {
            tickets.removeFirst(head)
            head = 0
            tickets.removeAll { $0.request == request }
        }
    }
}

/// What a job that outlived its request still holds. A storage callback
/// that ignores cancellation stays counted until it actually exits.
struct AbandonedJob: Sendable {
    var servingSlot: InboundContentRequest?
    var servingVolumeBytes = 0
    var localSlot = false
}

enum JobOwner: Sendable {
    case serving(InboundContentRequest)
    case volumeFetch(OpID)
    case abandoned(AbandonedJob)
}

/// A request being served, as explicit state: which step it is on and what
/// it holds. A granted slot, a finished job or a writable connection moves
/// it on in the same step.
struct ServingRequest: Sendable {
    enum Kind: Sendable {
        case volume
        case bundle
    }

    enum Phase: Sendable, Equatable {
        case waitingSlot
        case listing(JobID)
        case authorizing(JobID)
        /// Waiting for room to hold a worst-case Volume while it is read.
        case waitingRead
        case reading(JobID)
        /// Waiting for the connection to take the next record.
        case sending
        /// Between steps, inside one step.
        case idle
    }

    let request: InboundContentRequest
    let ref: SessionRef
    let rootCID: String
    let kind: Kind
    var phase: Phase = .waitingSlot
    /// The deadline passed while a job was out; the request ends when it exits.
    var timedOut = false
    /// Its current slot came from the wait queue, so what it sends is
    /// reported as contended (`PeerLedger.recordContendedSent`).
    var contended = false

    // A bundle's Volumes, the root's own first.
    var bundleRoots: [String]?
    var bundleIndex = 0
    /// The Volume being read or sent.
    var volumeRoot: String
    /// Bytes of the serving Volume budget this request holds.
    var heldBytes = 0
    var archive = Data()
    var entryCount = 0
    var chunkIndex = 0
    var chunkCount = 0
    var chunkPayloadBytes = 0
    /// A single record waiting for the connection: a bundle's end.
    var pendingMessage: Message?
}

private enum VolumeSendOutcome {
    case sent
    /// Nothing of the Volume went out.
    case notSent
    /// The request was cancelled or its session ended.
    case interrupted
}

extension IvyCore {
    static func servingOrder(_ lhs: InboundContentRequest, _ rhs: InboundContentRequest) -> Bool {
        (lhs.peer.publicKey, lhs.link, lhs.requestID) < (rhs.peer.publicKey, rhs.link, rhs.requestID)
    }

    // MARK: - Jobs

    mutating func startJob(_ job: Job, owner: JobOwner) -> JobID {
        let id = JobID(makeID())
        jobs[id] = owner
        emit(.startJob(id, job))
        return id
    }

    /// Cancels a job nobody waits for any more. What it holds stays held
    /// until the shell reports that it finished.
    mutating func abandonJob(_ id: JobID, holding hold: AbandonedJob) {
        guard jobs[id] != nil else { return }
        jobs[id] = .abandoned(hold)
        emit(.cancelJob(id))
    }

    mutating func jobFinished(_ id: JobID, _ result: JobResult) {
        guard let owner = jobs.removeValue(forKey: id) else { return }
        switch owner {
        case .serving(let request):
            servingJobFinished(request, job: id, result)
        case .volumeFetch(let fetch):
            volumeFetchLocalReadFinished(fetch, job: id, result)
        case .abandoned(let hold):
            if hold.localSlot { activeLocalContentRequestCount -= 1 }
            if hold.servingVolumeBytes > 0 { releaseServingVolumeBytes(hold.servingVolumeBytes) }
            if let slot = hold.servingSlot { servingContentRequests.remove(slot) }
            dispatchServingSlots()
        }
    }

    // MARK: - The serving queue

    /// A peer's share of contended serving: 1 plus log2(1 + credit / 1 KiB),
    /// where credit is the verified content it served this node plus its
    /// prepaid balance (`PeerLedger.servingPriority`). Logarithmic, so credit multiplies a
    /// peer's share (1 MiB ≈ 11×, 1 GiB ≈ 21×) without reducing a peer with
    /// no credit to a negligible one.
    func servingWeight(of peer: PeerID) -> Double {
        1 + log2(1 + max(0, ledger.servingPriority(for: peer)) / 1_024)
    }

    var hasFreeServingSlot: Bool {
        servingContentRequests.count + activeLocalContentRequestCount
            < config.maxConcurrentContentRequests
    }

    /// Admits a request to be served, now or once a slot frees. True when
    /// it holds a slot already.
    ///
    /// With a free slot and nobody waiting, the request is served at once in
    /// arrival order, whoever asks: one peer alone may hold every slot. Under
    /// pressure it waits, and freed slots are shared among the waiting peers
    /// in proportion to their weight (see `servingWeight`): peers that served
    /// this node verified content get proportionally more, and a peer with no
    /// credit, such as a node syncing from scratch, always advances. A
    /// request is never refused for load, and `requestTimeout` does not run
    /// while it waits. Local reads take any free slot without queueing: the
    /// node's own needs come first.
    private mutating func takeServingSlotOrWait(_ request: InboundContentRequest) -> Bool {
        if servingTickets.isEmpty, hasFreeServingSlot {
            servingContentRequests.insert(request)
            serving[request]?.contended = false
            return true
        }
        serving[request]?.contended = true
        nextServingTicketArrival &+= 1
        servingTickets[request] = nextServingTicketArrival
        // Stride scheduling: a peer that starts waiting begins one stride
        // ahead of the virtual time and keeps its pass while it waits, so
        // re-joining cannot jump the peers already waiting.
        var peer = waitingServingPeers[request.peer]
            ?? WaitingServingPeer(pass: servingVirtualTime + 1 / servingWeight(of: request.peer))
        peer.append(request, arrival: nextServingTicketArrival)
        waitingServingPeers[request.peer] = peer
        return false
    }

    private mutating func removeServingTicket(_ request: InboundContentRequest) {
        guard servingTickets.removeValue(forKey: request) != nil,
              var peer = waitingServingPeers[request.peer] else { return }
        peer.remove(request)
        waitingServingPeers[request.peer] = peer.isEmpty ? nil : peer
    }

    /// Hands freed slots to waiting requests by stride scheduling: the
    /// waiting peer with the lowest pass is served next (the older request
    /// among equals) and its pass advances by 1 / weight, so each waiting
    /// peer's share of slots is proportional to its weight.
    mutating func dispatchServingSlots() {
        var granted: [InboundContentRequest] = []
        while hasFreeServingSlot, !servingTickets.isEmpty {
            var chosen: (ticket: (request: InboundContentRequest, arrival: UInt64), pass: Double)?
            for waiting in waitingServingPeers.values {
                guard let ticket = waiting.first else { continue }
                if let current = chosen,
                   waiting.pass > current.pass
                    || (waiting.pass == current.pass && ticket.arrival > current.ticket.arrival) {
                    continue
                }
                chosen = (ticket, waiting.pass)
            }
            guard let next = chosen else { break }
            let peer = next.ticket.request.peer
            // Virtual time never moves backwards, or peers joining after it
            // would start below those already waiting.
            servingVirtualTime = max(servingVirtualTime, next.pass)
            let stride = 1 / servingWeight(of: peer)
            waitingServingPeers[peer]?.pass = next.pass + stride
            removeServingTicket(next.ticket.request)
            servingContentRequests.insert(next.ticket.request)
            granted.append(next.ticket.request)
        }
        for request in granted { servingSlotGranted(request) }
    }

    // MARK: - Admission

    mutating func beginVolumeRequest(
        requestID: UInt64,
        rootCID: String,
        bundle: Bool,
        from ref: SessionRef
    ) {
        guard MessageLimits.accepts(rootCID) else { return }
        let request = InboundContentRequest(peer: ref.key.peerID, link: ref.link, requestID: requestID)
        guard serving[request] == nil, !servingContentRequests.contains(request) else {
            _ = enqueue(.contentUnavailable(requestID: requestID), on: ref)
            return
        }
        admit(ServingRequest(
            request: request,
            ref: ref,
            rootCID: rootCID,
            kind: bundle ? .bundle : .volume,
            volumeRoot: rootCID))
    }

    private mutating func admit(_ entry: ServingRequest) {
        serving[entry.request] = entry
        if takeServingSlotOrWait(entry.request) { servingSlotGranted(entry.request) }
    }

    // MARK: - Steps

    private mutating func servingSlotGranted(_ request: InboundContentRequest) {
        guard let entry = serving[request] else { return }
        guard isCurrent(entry.ref) else { return endServing(request) }
        switch entry.kind {
        case .volume:
            startServingVolume(request)
        case .bundle:
            if entry.bundleRoots != nil { return startServingVolume(request) }
            guard hasContentSource else { return sendBundleEnd(request) }
            let job = startJob(.readVolumeBundle(rootCID: entry.rootCID), owner: .serving(request))
            serving[request]?.phase = .listing(job)
        }
    }

    /// Authorizes, reads, reserves, times and streams one Volume under a
    /// request that holds a serving slot.
    private mutating func startServingVolume(_ request: InboundContentRequest) {
        guard let entry = serving[request] else { return }
        guard hasContentSource, let session = session(entry.ref) else {
            return volumeFinished(request, .notSent)
        }
        let job = startJob(
            .authorizeVolume(authenticatedPeer(session), rootCID: entry.volumeRoot),
            owner: .serving(request))
        serving[request]?.phase = .authorizing(job)
    }

    private mutating func servingJobFinished(
        _ request: InboundContentRequest,
        job: JobID,
        _ result: JobResult
    ) {
        guard var entry = serving[request] else { return }
        let phase = entry.phase
        entry.phase = .idle
        serving[request] = entry
        // A Volume's requester keeps its own deadline.
        if entry.timedOut { return endServing(request) }
        switch phase {
        case .listing(job):
            guard case .roots(let roots) = result, roots.first == entry.rootCID else {
                return sendBundleEnd(request)
            }
            entry.bundleRoots = roots
            entry.bundleIndex = 0
            entry.volumeRoot = entry.rootCID
            serving[request] = entry
            startServingVolume(request)

        case .authorizing(job):
            guard result == .authorized(true) else { return volumeFinished(request, .notSent) }
            guard isCurrent(entry.ref) else { return volumeFinished(request, .interrupted) }
            if tryReserveServingVolumeRead() {
                beginVolumeRead(request)
            } else {
                serving[request]?.phase = .waitingRead
                servingVolumeReadWaiters.append(request)
            }

        case .reading(job):
            var entries: [ContentEntry] = []
            if case .entries(let read) = result { entries = read }
            volumeRead(request, entries)

        default:
            return
        }
    }

    // MARK: - Sending a Volume

    private mutating func beginVolumeRead(_ request: InboundContentRequest) {
        guard var entry = serving[request] else {
            // Its reservation was taken for it; give it back.
            return releaseServingVolumeBytes(MessageLimits.maxVolumeArchiveBytes)
        }
        // A Volume's size is unknown until it is read, so the read holds a
        // worst-case reservation.
        entry.heldBytes = MessageLimits.maxVolumeArchiveBytes
        timers.set(.serving(request), at: now.uptime + config.requestTimeout)
        let job = startJob(
            .readVolume(rootCID: entry.volumeRoot, maxDataBytes: MessageLimits.maxVolumeArchiveBytes),
            owner: .serving(request))
        entry.phase = .reading(job)
        serving[request] = entry
    }

    private mutating func volumeRead(_ request: InboundContentRequest, _ entries: [ContentEntry]) {
        guard var entry = serving[request] else { return }
        let encoded = VolumeArchive.encode(entries: entries, rootCID: entry.volumeRoot)
        // Once encoded, only the archive stays in memory while it is sent,
        // so the reservation shrinks to its size.
        if let encoded, encoded.data.count < entry.heldBytes {
            let surplus = entry.heldBytes - encoded.data.count
            entry.heldBytes = encoded.data.count
            serving[request] = entry
            releaseServingVolumeBytes(surplus)
        }
        guard isCurrent(entry.ref),
              let archive = encoded,
              let payloadBytes = Message.volumeChunkDataBudget(
                rootCID: entry.volumeRoot,
                maxFrameSize: effectiveOutboundFrameSize(for: entry.ref.link),
                relayed: links[entry.ref.link]?.isDirect == false),
              payloadBytes > 0 else {
            return volumeFinished(request, .notSent)
        }
        let chunkCount = (archive.data.count + payloadBytes - 1) / payloadBytes
        guard chunkCount > 0, chunkCount <= Int(MessageLimits.maxVolumeChunkCount) else {
            return volumeFinished(request, .notSent)
        }
        entry.archive = archive.data
        entry.entryCount = archive.entries.count
        entry.chunkIndex = 0
        entry.chunkCount = chunkCount
        entry.chunkPayloadBytes = payloadBytes
        serving[request] = entry
        sendVolumeChunks(request)
    }

    /// The chunk cursor: sends in order until the Volume is out or the
    /// connection stops taking records, and picks up from there when it can.
    private mutating func sendVolumeChunks(_ request: InboundContentRequest) {
        while let entry = serving[request] {
            guard isCurrent(entry.ref) else { return volumeFinished(request, .interrupted) }
            guard entry.chunkIndex < entry.chunkCount else { return volumeFinished(request, .sent) }
            let start = entry.chunkIndex * entry.chunkPayloadBytes
            let end = min(start + entry.chunkPayloadBytes, entry.archive.count)
            let base = entry.archive.startIndex
            let chunk = Message.volumeChunk(
                requestID: request.requestID,
                rootCID: entry.volumeRoot,
                index: UInt16(entry.chunkIndex),
                count: UInt16(entry.chunkCount),
                totalEntries: UInt16(entry.entryCount),
                totalBytes: UInt64(entry.archive.count),
                payload: Data(entry.archive[(base + start)..<(base + end)]))
            switch enqueue(chunk, on: entry.ref) {
            case .enqueued:
                if entry.contended { ledger.recordContendedSent(peer: request.peer, bytes: end - start) }
                serving[request]?.chunkIndex += 1
            case .backpressured:
                guard awaitWritable(entry.ref.link, .serving(request)) else {
                    return volumeFinished(request, .interrupted)
                }
                serving[request]?.phase = .sending
                return
            case .notConnected, .locallyRejected:
                _ = enqueue(.contentUnavailable(requestID: request.requestID), on: entry.ref)
                return volumeFinished(request, .interrupted)
            }
        }
    }

    private mutating func volumeFinished(_ request: InboundContentRequest, _ outcome: VolumeSendOutcome) {
        guard var entry = serving[request] else { return }
        timers.cancel(.serving(request))
        let held = entry.heldBytes
        entry.heldBytes = 0
        entry.archive = Data()
        entry.chunkCount = 0
        serving[request] = entry
        releaseServingVolumeBytes(held)
        guard serving[request] != nil else { return }

        guard case .bundle = entry.kind, let roots = entry.bundleRoots else {
            if outcome == .notSent { return refuseServing(request) }
            return endServing(request)
        }
        // Each Volume of the bundle is read, reserved and sent as a requested
        // Volume is. One that cannot be sent is left out; without the root's
        // own there is no bundle.
        if outcome == .interrupted { return endServing(request) }
        if outcome == .notSent, entry.volumeRoot == entry.rootCID { return sendBundleEnd(request) }
        let next = entry.bundleIndex + 1
        guard next < roots.count else { return sendBundleEnd(request) }
        entry.bundleIndex = next
        entry.volumeRoot = roots[next]
        entry.phase = .waitingSlot
        serving[request] = entry
        // Between two Volumes the request gives up its serving slot and
        // queues for the next, so a bundle takes no more of a contended
        // server than the same Volumes requested one at a time.
        servingContentRequests.remove(request)
        dispatchServingSlots()
        guard serving[request] != nil else { return }
        if takeServingSlotOrWait(request) { servingSlotGranted(request) }
    }

    private mutating func sendBundleEnd(_ request: InboundContentRequest) {
        sendServingMessage(request, .volumeBundleEnd(requestID: request.requestID))
    }

    // MARK: - Replies

    /// Sends the request's last record, waiting out a backpressured connection.
    private mutating func sendServingMessage(_ request: InboundContentRequest, _ message: Message) {
        guard let entry = serving[request] else { return }
        guard isCurrent(entry.ref) else { return endServing(request) }
        switch enqueue(message, on: entry.ref) {
        case .enqueued:
            endServing(request)
        case .backpressured:
            guard awaitWritable(entry.ref.link, .serving(request)) else {
                return refuseServing(request)
            }
            serving[request]?.pendingMessage = message
            serving[request]?.phase = .sending
        case .notConnected, .locallyRejected:
            refuseServing(request)
        }
    }

    mutating func servingBecameWritable(_ request: InboundContentRequest, writable: Bool) {
        guard let entry = serving[request], entry.phase == .sending else { return }
        serving[request]?.phase = .idle
        if let message = entry.pendingMessage {
            guard writable else { return refuseServing(request) }
            serving[request]?.pendingMessage = nil
            sendServingMessage(request, message)
        } else {
            guard writable else {
                _ = enqueue(.contentUnavailable(requestID: request.requestID), on: entry.ref)
                return volumeFinished(request, .interrupted)
            }
            sendVolumeChunks(request)
        }
    }

    /// Answers `contentUnavailable` and ends the request.
    private mutating func refuseServing(_ request: InboundContentRequest) {
        if let entry = serving[request] {
            _ = enqueue(.contentUnavailable(requestID: request.requestID), on: entry.ref)
        }
        endServing(request)
    }

    // MARK: - Ending

    /// Releases everything the request holds and hands its slot on.
    private mutating func endServing(_ request: InboundContentRequest) {
        guard let entry = serving.removeValue(forKey: request) else { return }
        timers.cancel(.serving(request))
        removeServingTicket(request)
        servingVolumeReadWaiters.removeAll { $0 == request }
        if entry.phase == .sending {
            removeWritabilityWaiter(.serving(request))
        }
        var hold = AbandonedJob(servingVolumeBytes: entry.heldBytes)
        switch entry.phase {
        case .listing(let job), .authorizing(let job), .reading(let job):
            // The job still runs: it keeps the slot and the bytes until it exits.
            if servingContentRequests.contains(request) { hold.servingSlot = request }
            abandonJob(job, holding: hold)
            return
        default:
            break
        }
        releaseServingVolumeBytes(entry.heldBytes)
        if servingContentRequests.remove(request) != nil { dispatchServingSlots() }
    }

    /// `requestTimeout` passed while the request held its capacity.
    mutating func servingTimedOut(_ request: InboundContentRequest) {
        guard let entry = serving[request] else { return }
        switch entry.phase {
        case .listing(let job), .authorizing(let job), .reading(let job):
            serving[request]?.timedOut = true
            emit(.cancelJob(job))
        case .sending:
            endServing(request)
        case .waitingSlot, .waitingRead, .idle:
            return
        }
    }

    /// The request's session ended, or the node stopped.
    mutating func cancelServing(_ request: InboundContentRequest) {
        endServing(request)
    }

    mutating func failAllServing() {
        for request in serving.keys.sorted(by: Self.servingOrder) { endServing(request) }
        servingTickets.removeAll()
        waitingServingPeers.removeAll()
        servingVolumeReadWaiters.removeAll()
    }

    // MARK: - The serving Volume budget

    /// With nothing reserved a read always fits, so a budget below one
    /// worst-case Volume serves one read at a time rather than none.
    private func servingVolumeFits(_ bytes: Int) -> Bool {
        reservedServingVolumeBytes == 0
            || bytes <= config.maxInFlightVolumeBytes - reservedServingVolumeBytes
    }

    /// Reserves a worst-case Volume read only if it fits now and no read is
    /// already waiting (waiting reads keep their turn).
    mutating func tryReserveServingVolumeRead() -> Bool {
        let worstCase = MessageLimits.maxVolumeArchiveBytes
        guard servingVolumeReadWaiters.isEmpty, servingVolumeFits(worstCase) else { return false }
        reservedServingVolumeBytes += worstCase
        return true
    }

    /// Returns `bytes` of serving reservation and admits the waiting reads
    /// that now fit, oldest first.
    mutating func releaseServingVolumeBytes(_ bytes: Int) {
        guard bytes > 0 else { return }
        precondition(reservedServingVolumeBytes >= bytes)
        reservedServingVolumeBytes -= bytes
        let worstCase = MessageLimits.maxVolumeArchiveBytes
        var admitted: [InboundContentRequest] = []
        while !servingVolumeReadWaiters.isEmpty, servingVolumeFits(worstCase) {
            reservedServingVolumeBytes += worstCase
            admitted.append(servingVolumeReadWaiters.removeFirst())
        }
        for request in admitted { beginVolumeRead(request) }
    }
}
