#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

struct VolumeAssembly: Sendable {
    let rootCID: String
    let chunkCount: UInt16
    let totalEntries: UInt16
    let totalBytes: Int
    var nextIndex: UInt16 = 0
    var chunks: [Data] = []
    var receivedBytes = 0
}

/// One `volumeRequest` or `volumeBundleRequest` on the wire, to one peer.
struct PendingVolumeRequest: Sendable {
    let rootCID: String
    let maximumArchiveBytes: Int
    let maximumEntries: Int
    /// A bundle request: Volumes accumulate until `volumeBundleEnd`.
    let bundle: Bool
    let fetch: OpID
    var candidateSessions: [PeerID: Data]
    var assemblies: [PeerID: VolumeAssembly] = [:]
    var volumes: [AttributedVolumeResponse] = []
    /// What the received `volumes` hold of the in-flight Volume budget.
    var receivedBytes = 0
    /// The roots of `volumes`: a bundle carries no Volume twice.
    var receivedRoots = Set<String>()
    var noBundle = false
    var ended = false
    var failure: VolumeFetchFailure?

    func matches(peer: PeerID, sessionID: Data?) -> Bool {
        candidateSessions[peer] == sessionID
    }

    /// What the request has to show for itself, however it ended.
    var response: AttributedVolumeBundleResponse {
        AttributedVolumeBundleResponse(
            volumes: volumes,
            noBundle: noBundle,
            ended: ended,
            // A bundle that did not end says why even with Volumes in hand.
            failure: volumes.isEmpty || (bundle && !ended) ? failure : nil)
    }
}

/// A Volume or bundle fetch: which sources have been asked and what is
/// outstanding. Candidates are asked one at a time, least loaded first.
struct VolumeFetch: Sendable {
    enum Plan: Sendable {
        /// Known providers, then connected peers, then fresh discovery.
        case discover
        /// Only the sessions named.
        case sessions([PeerID: AuthenticatedPeer], bundle: Bool)
    }

    enum Phase: Sendable, Equatable {
        case starting
        case localRead(JobID)
        case connecting(OpID)
        case searching
        /// Every candidate is at its in-flight limit.
        case waitingSlot
        case asking(UInt64, peer: PeerID)
    }

    let request: RequestID
    let rootCID: String
    let maximumArchiveBytes: Int
    let maximumEntries: Int
    let plan: Plan
    var phase: Phase = .starting
    /// 0 known providers, 1 connected peers, 2 discovered providers.
    var step = 0
    var searched = false
    var cached: [PeerEndpoint] = []
    var fresh: [PeerEndpoint] = []
    var asked = Set<PeerID>()
    var remaining: [PeerID] = []
    var last = AttributedVolumeBundleResponse.empty
    var lastSingle = AttributedVolumeResponse.empty

    var isBundle: Bool {
        if case .sessions(_, true) = plan { return true }
        return false
    }
}

extension IvyCore {
    private var contentExchangeEnabled: Bool {
        config.mode.usesOverlayServices || config.privateContentExchangeEnabled
    }

    mutating func handleContentUnavailable(requestID: UInt64, from peer: PeerID, sessionID: Data?) {
        guard let pending = pendingVolumeRequests[requestID],
              pending.matches(peer: peer, sessionID: sessionID) else { return }
        markVolumeCandidateDone(requestID: requestID, peer: peer)
    }

    // MARK: - Volumes: the fetch

    /// Fetches one complete Volume without accepting a response whose declared
    /// archive or entry count exceeds the caller's local capacity. Provider
    /// selection may use any connected endpoint advertising the root.
    mutating func fetchVolume(
        _ request: RequestID,
        rootCID: String,
        maximumArchiveBytes: Int,
        maximumEntries: Int
    ) {
        guard MessageLimits.accepts(rootCID), maximumArchiveBytes > 0, maximumEntries > 0 else {
            return complete(request, .volume(.empty))
        }
        let id = makeID()
        volumeFetches[id] = VolumeFetch(
            request: request,
            rootCID: rootCID,
            maximumArchiveBytes: min(maximumArchiveBytes, MessageLimits.maxVolumeArchiveBytes),
            maximumEntries: min(maximumEntries, Int(MessageLimits.maxVolumeEntryCount)),
            plan: .discover)
        requests[request] = .volumeFetch(id)

        if hasContentSource, hasFreeServingSlot, tryReserveServingVolumeRead() {
            activeLocalContentRequestCount += 1
            let job = startJob(
                .readVolume(rootCID: rootCID, maxDataBytes: MessageLimits.maxVolumeArchiveBytes),
                owner: .volumeFetch(id))
            volumeFetches[id]?.phase = .localRead(job)
        } else {
            volumeFetchFromNetwork(id)
        }
    }

    /// Fetches one complete Volume from the exact authenticated endpoint
    /// session that advertised it, rejecting a response whose advertised
    /// boundary exceeds the caller's needs before allocating its archive.
    mutating func fetchVolume(
        _ request: RequestID,
        rootCID: String,
        from peer: AuthenticatedPeer,
        maximumArchiveBytes: Int,
        maximumEntries: Int
    ) {
        guard MessageLimits.accepts(rootCID), maximumArchiveBytes > 0, maximumEntries > 0 else {
            return complete(request, .volume(.empty))
        }
        let id = makeID()
        var fetch = VolumeFetch(
            request: request,
            rootCID: rootCID,
            maximumArchiveBytes: min(maximumArchiveBytes, MessageLimits.maxVolumeArchiveBytes),
            maximumEntries: min(maximumEntries, Int(MessageLimits.maxVolumeEntryCount)),
            plan: .sessions([peer.id: peer], bundle: false))
        fetch.remaining = [peer.id]
        volumeFetches[id] = fetch
        requests[request] = .volumeFetch(id)
        askNextVolumePeer(id)
    }

    /// Fetches the Volumes a peer bundles under `rootCID` with one request:
    /// every Volume the peer sent before its answer ended, the root's own
    /// first. Only the sessions named are asked, one at a time (least loaded
    /// first, as Volume requests are), until one sends a Volume: a bundle
    /// request is a message a peer must be known to speak, which is the
    /// caller's to know, as is whether to ask again a peer whose answer did
    /// not end (`ended`).
    mutating func fetchVolumeBundle(
        _ request: RequestID,
        rootCID: String,
        from peers: [AuthenticatedPeer]
    ) {
        guard MessageLimits.accepts(rootCID) else {
            return complete(request, .volumeBundle(.notSent))
        }
        var sessions: [PeerID: AuthenticatedPeer] = [:]
        var order: [PeerID] = []
        for peer in peers {
            if sessions[peer.id] == nil { order.append(peer.id) }
            sessions[peer.id] = peer
        }
        let id = makeID()
        var fetch = VolumeFetch(
            request: request,
            rootCID: rootCID,
            maximumArchiveBytes: MessageLimits.maxVolumeArchiveBytes,
            maximumEntries: Int(MessageLimits.maxVolumeEntryCount),
            plan: .sessions(sessions, bundle: true))
        fetch.remaining = order
        fetch.last = .notSent
        volumeFetches[id] = fetch
        requests[request] = .volumeFetch(id)
        askNextVolumePeer(id)
    }

    mutating func volumeFetchLocalReadFinished(_ id: OpID, job: JobID, _ result: JobResult) {
        activeLocalContentRequestCount -= 1
        releaseServingVolumeBytes(MessageLimits.maxVolumeArchiveBytes)
        dispatchServingSlots()
        guard let fetch = volumeFetches[id], fetch.phase == .localRead(job) else { return }
        volumeFetches[id]?.phase = .starting
        if case .entries(let entries) = result,
           let archive = VolumeArchive.encode(entries: entries, rootCID: fetch.rootCID) {
            return completeVolumeFetch(id, .volume(AttributedVolumeResponse(
                rootCID: fetch.rootCID,
                entries: Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.cid, $0.data) }),
                servedBy: nil)))
        }
        volumeFetchFromNetwork(id)
    }

    private mutating func volumeFetchFromNetwork(_ id: OpID) {
        guard let fetch = volumeFetches[id] else { return }
        guard isRunning, contentExchangeEnabled else { return completeVolumeFetch(id, .volume(.empty)) }
        let cached = cachedProviderEndpoints(rootCID: fetch.rootCID)
        volumeFetches[id]?.cached = cached
        runVolumeStep(id)
    }

    /// Known providers (peers that announced the root or were referred for
    /// it; having served it is not a record), then the peers already
    /// connected, then the DHT. A connected peer without the Volume answers
    /// `contentUnavailable` at once, so asking them costs one round trip
    /// before any DHT lookup (Bitswap's order). Each step asks only peers not
    /// yet asked, and a miss returns the last empty answer so its failure
    /// (local capacity) still reaches the caller.
    private mutating func runVolumeStep(_ id: OpID) {
        while let fetch = volumeFetches[id] {
            guard isRunning else { return completeVolumeFetch(id, .volume(.empty)) }
            switch fetch.step {
            case 0:
                if let group = startConnectGroup(fetch.cached, waiter: .volumeFetch(id)) {
                    volumeFetches[id]?.phase = .connecting(group)
                    return
                }
            case 1:
                break
            case 2:
                if !fetch.searched {
                    volumeFetches[id]?.phase = .searching
                    startProviderSearch(rootCID: fetch.rootCID, waiter: .volumeFetch(id))
                    return
                }
            default:
                return completeVolumeFetch(id, .volume(fetch.lastSingle))
            }
            if askVolumeStepPeers(id) { return }
        }
    }

    mutating func volumeFetchConnectGroupFinished(_ id: OpID, group: OpID) {
        guard volumeFetches[id]?.phase == .connecting(group) else { return }
        volumeFetches[id]?.phase = .starting
        if !askVolumeStepPeers(id) { runVolumeStep(id) }
    }

    mutating func volumeFetchProviderSearchFinished(
        _ id: OpID,
        search: OpID,
        endpoints: [PeerEndpoint]
    ) {
        guard var fetch = volumeFetches[id], fetch.phase == .searching else { return }
        fetch.searched = true
        fetch.fresh = endpoints
        fetch.phase = .starting
        volumeFetches[id] = fetch
        guard isRunning else { return completeVolumeFetch(id, .volume(.empty)) }
        if let group = startConnectGroup(endpoints + fetch.cached, waiter: .volumeFetch(id)) {
            volumeFetches[id]?.phase = .connecting(group)
        } else if !askVolumeStepPeers(id) {
            runVolumeStep(id)
        }
    }

    /// Asks this step's peers that have not been asked. False when there are
    /// none, after moving to the next step.
    private mutating func askVolumeStepPeers(_ id: OpID) -> Bool {
        guard var fetch = volumeFetches[id] else { return true }
        guard isRunning else {
            completeVolumeFetch(id, .volume(.empty))
            return true
        }
        let peers: [PeerID]
        switch fetch.step {
        case 0:
            peers = connectedProviderIDs(for: fetch.rootCID)
        case 1:
            peers = connectedFallbackCandidates(rootCID: fetch.rootCID)
        default:
            peers = connectedProviderIDs(for: fetch.rootCID, including: fetch.fresh)
        }
        var batch: [PeerID] = []
        for peer in peers where !fetch.asked.contains(peer) && !batch.contains(peer) {
            batch.append(peer)
            if batch.count == config.maxContentCandidates { break }
        }
        guard !batch.isEmpty else {
            fetch.step += 1
            volumeFetches[id] = fetch
            return false
        }
        fetch.asked.formUnion(batch)
        fetch.remaining = batch
        fetch.last = .empty
        volumeFetches[id] = fetch
        askNextVolumePeer(id)
        return true
    }

    /// Asks the candidates one at a time, least loaded first, moving on when
    /// one misses. Each peer has at most `maxOutstandingVolumeRequestsPerPeer`
    /// requests from this node in flight; when every candidate is at that
    /// limit the request waits for one to free rather than piling on.
    private mutating func askNextVolumePeer(_ id: OpID) {
        while var fetch = volumeFetches[id] {
            guard !fetch.remaining.isEmpty else { return volumeCandidatesExhausted(id) }
            guard isRunning else { return finishVolumeFetch(id, .empty) }

            // Peers that have been timing out last, then the least loaded,
            // ties at random so no peer is always asked first.
            let open = fetch.remaining.filter {
                outstandingVolumeRequests[$0, default: 0] < config.maxOutstandingVolumeRequestsPerPeer
            }
            guard let peer = random.shuffled(open).min(by: { lhs, rhs in
                (volumeTimeoutStreaks[lhs, default: 0], outstandingVolumeRequests[lhs, default: 0])
                    < (volumeTimeoutStreaks[rhs, default: 0], outstandingVolumeRequests[rhs, default: 0])
            }) else {
                fetch.phase = .waitingSlot
                volumeFetches[id] = fetch
                if !outstandingVolumeSlotWaiters.contains(id) { outstandingVolumeSlotWaiters.append(id) }
                return
            }
            outstandingVolumeRequests[peer, default: 0] += 1
            fetch.remaining.removeAll { $0 == peer }
            fetch.phase = .starting
            volumeFetches[id] = fetch

            var exactPeer: AuthenticatedPeer?
            if case .sessions(let sessions, _) = fetch.plan { exactPeer = sessions[peer] }
            switch requestVolume(fetch, id: id, from: peer, exactPeer: exactPeer) {
            case .sent(let requestID):
                volumeFetches[id]?.phase = .asking(requestID, peer: peer)
                return
            case .answered(let response):
                releaseOutstandingVolumeSlot(peer)
                if recordVolumeAnswer(id, response) { return }
            }
        }
    }

    private enum VolumeRequestStart {
        case sent(UInt64)
        case answered(AttributedVolumeBundleResponse)
    }

    /// One Volume request, or one bundle request, to one peer.
    private mutating func requestVolume(
        _ fetch: VolumeFetch,
        id: OpID,
        from peer: PeerID,
        exactPeer: AuthenticatedPeer?
    ) -> VolumeRequestStart {
        guard isRunning else { return .answered(.empty) }
        let requestID = makeWireOperationID(avoiding: Set(pendingVolumeRequests.keys))
        guard pendingVolumeRequests.count < config.maxPendingRequests else {
            return .answered(.localCapacityUnavailable)
        }
        let message = fetch.isBundle
            ? Message.volumeBundleRequest(requestID: requestID, rootCID: fetch.rootCID)
            : Message.volumeRequest(requestID: requestID, rootCID: fetch.rootCID)
        var sessionID: Data?
        if let exactPeer {
            if let session = endpointSession(for: exactPeer.key),
               session.sessionID.bytes == exactPeer.sessionID,
               case .enqueued = enqueue(message, on: session.ref) {
                sessionID = exactPeer.sessionID
            }
        } else if let session = endpointSession(for: peer),
                  case .enqueued = enqueue(message, on: session.ref) {
            sessionID = session.sessionID.bytes
        }
        guard let sessionID else { return .answered(fetch.isBundle ? .notSent : .empty) }
        pendingVolumeRequests[requestID] = PendingVolumeRequest(
            rootCID: fetch.rootCID,
            maximumArchiveBytes: fetch.maximumArchiveBytes,
            maximumEntries: fetch.maximumEntries,
            bundle: fetch.isBundle,
            fetch: id,
            candidateSessions: [peer: sessionID])
        timers.set(.volumeRequest(requestID), at: now.uptime + config.requestTimeout)
        return .sent(requestID)
    }

    /// Takes one peer's answer. True when the fetch ended on it.
    private mutating func recordVolumeAnswer(
        _ id: OpID,
        _ response: AttributedVolumeBundleResponse
    ) -> Bool {
        guard var fetch = volumeFetches[id] else { return true }
        if fetch.isBundle {
            if !response.volumes.isEmpty {
                completeVolumeFetch(id, .volumeBundle(response))
                return true
            }
            // A peer that was asked is not forgotten for one that was not.
            if response.failure != .notSent { fetch.last = response }
        } else {
            if !response.volumes.isEmpty {
                fetch.last = response
                fetch.remaining = []
            } else if response.failure != nil || fetch.last.failure == nil {
                // Keep a failure (local capacity) over a later plain miss.
                fetch.last = response
            }
        }
        volumeFetches[id] = fetch
        return false
    }

    private mutating func volumeAskFinished(
        _ id: OpID,
        requestID: UInt64,
        _ response: AttributedVolumeBundleResponse
    ) {
        guard case .asking(requestID, let peer) = volumeFetches[id]?.phase else { return }
        volumeFetches[id]?.phase = .starting
        releaseOutstandingVolumeSlot(peer)
        if !recordVolumeAnswer(id, response) { askNextVolumePeer(id) }
    }

    private mutating func volumeCandidatesExhausted(_ id: OpID) {
        guard var fetch = volumeFetches[id] else { return }
        switch fetch.plan {
        case .sessions(_, let bundle):
            completeVolumeFetch(id, bundle ? .volumeBundle(fetch.last) : .volume(fetch.last.single))
        case .discover:
            let single = fetch.last.single
            if !single.entries.isEmpty { return completeVolumeFetch(id, .volume(single)) }
            fetch.lastSingle = single
            fetch.step += 1
            volumeFetches[id] = fetch
            runVolumeStep(id)
        }
    }

    /// Ends a fetch whose caller has gone or whose node stopped.
    mutating func finishVolumeFetch(_ id: OpID, _ response: AttributedVolumeResponse) {
        guard let fetch = volumeFetches[id] else { return }
        guard fetch.isBundle else { return completeVolumeFetch(id, .volume(response)) }
        var last = fetch.last
        if case .asking(let requestID, _) = fetch.phase {
            // A peer was asked. A caller that gives up keeps the Volumes
            // already complete; a node that stops returns nothing.
            if isRunning, let pending = pendingVolumeRequests[requestID] {
                last = pending.response
            } else {
                last = .empty
            }
        }
        completeVolumeFetch(id, .volumeBundle(last))
    }

    private mutating func completeVolumeFetch(_ id: OpID, _ result: RequestResult) {
        guard let fetch = volumeFetches.removeValue(forKey: id) else { return }
        switch fetch.phase {
        case .starting:
            break
        case .localRead(let job):
            abandonJob(job, holding: AbandonedJob(
                servingVolumeBytes: MessageLimits.maxVolumeArchiveBytes, localSlot: true))
        case .connecting(let group):
            cancelConnectGroup(group)
        case .searching:
            for (search, entry) in providerSearches where entry.waiter == .volumeFetch(id) {
                finishProviderSearch(search, [])
            }
        case .waitingSlot:
            outstandingVolumeSlotWaiters.removeAll { $0 == id }
        case .asking(let requestID, let peer):
            resolveVolumeRequest(requestID: requestID)
            releaseOutstandingVolumeSlot(peer)
        }
        if requests[fetch.request] != nil { complete(fetch.request, result) }
    }

    /// Frees a peer's in-flight slot; waiting fetches re-check their candidates.
    private mutating func releaseOutstandingVolumeSlot(_ peer: PeerID) {
        let count = outstandingVolumeRequests[peer, default: 0] - 1
        outstandingVolumeRequests[peer] = count > 0 ? count : nil
        let waiters = outstandingVolumeSlotWaiters
        outstandingVolumeSlotWaiters.removeAll()
        for waiter in waiters where volumeFetches[waiter]?.phase == .waitingSlot {
            askNextVolumePeer(waiter)
        }
    }

    // MARK: - Volumes: one wire request

    mutating func handleVolumeChunk(
        requestID: UInt64,
        rootCID: String,
        index: UInt16,
        count: UInt16,
        totalEntries: UInt16,
        totalBytes: UInt64,
        payload: Data,
        from peer: PeerID,
        sessionID: Data?,
        relayed: Bool
    ) {
        guard var pending = pendingVolumeRequests[requestID],
              pending.matches(peer: peer, sessionID: sessionID) else { return }
        // A lone Volume, and a bundle's first, is the root's own; a bundle
        // carries no Volume twice.
        guard pending.volumes.isEmpty
                ? rootCID == pending.rootCID
                : !pending.receivedRoots.contains(rootCID),
              count > 0,
              count <= MessageLimits.maxVolumeChunkCount,
              index < count,
              totalEntries > 0,
              totalBytes > 0,
              totalBytes <= UInt64(MessageLimits.maxVolumeArchiveBytes),
              !payload.isEmpty,
              let maxChunkBytes = Message.volumeChunkDataBudget(
                rootCID: rootCID,
                maxFrameSize: config.protocolMaxFrameSize,
                relayed: relayed),
              payload.count <= maxChunkBytes else {
            rejectVolumeCandidate(requestID: requestID, peer: peer)
            return
        }
        let byteCount = Int(totalBytes)
        var assembly: VolumeAssembly
        if let existing = pending.assemblies[peer] {
            assembly = existing
            guard assembly.rootCID == rootCID,
                  assembly.chunkCount == count,
                  assembly.totalEntries == totalEntries,
                  assembly.totalBytes == byteCount,
                  assembly.nextIndex == index else {
                rejectVolumeCandidate(requestID: requestID, peer: peer)
                return
            }
        } else {
            guard index == 0 else {
                rejectVolumeCandidate(requestID: requestID, peer: peer)
                return
            }
            // Caller-local capacity is not part of the wire request. A
            // provider serving a globally valid complete Volume has not
            // violated protocol merely because this consumer needs less.
            guard totalEntries <= UInt16(clamping: pending.maximumEntries),
                  totalBytes <= UInt64(pending.maximumArchiveBytes) else {
                markVolumeCandidateDone(
                    requestID: requestID, peer: peer, failure: .callerBoundaryExceeded)
                return
            }
            guard byteCount <= config.maxInFlightVolumeBytes - reservedVolumeBytes else {
                markVolumeCandidateDone(
                    requestID: requestID, peer: peer, failure: .localCapacityUnavailable)
                return
            }
            assembly = VolumeAssembly(
                rootCID: rootCID,
                chunkCount: count,
                totalEntries: totalEntries,
                totalBytes: byteCount)
            reservedVolumeBytes += byteCount
            pending.assemblies[peer] = assembly
            pendingVolumeRequests[requestID] = pending
        }
        guard payload.count <= assembly.totalBytes - assembly.receivedBytes else {
            rejectVolumeCandidate(requestID: requestID, peer: peer)
            return
        }
        guard payload.count <= config.maxInFlightVolumeBytes - inFlightVolumeBytes else {
            markVolumeCandidateDone(
                requestID: requestID, peer: peer, failure: .localCapacityUnavailable)
            return
        }
        assembly.chunks.append(payload)
        assembly.receivedBytes += payload.count
        assembly.nextIndex += 1
        inFlightVolumeBytes += payload.count
        // Stored before anything can reject it: a rejection releases what
        // the stored assembly holds, which must include these bytes.
        pending.assemblies[peer] = assembly
        pendingVolumeRequests[requestID] = pending

        if assembly.nextIndex < assembly.chunkCount {
            if assembly.receivedBytes >= assembly.totalBytes {
                rejectVolumeCandidate(requestID: requestID, peer: peer)
            }
            return
        }

        var archive = Data(capacity: assembly.receivedBytes)
        for chunk in assembly.chunks { archive.append(chunk) }
        guard assembly.receivedBytes == assembly.totalBytes,
              let entries = VolumeArchive.decode(
                archive, rootCID: rootCID, expectedEntries: totalEntries) else {
            rejectVolumeCandidate(requestID: requestID, peer: peer)
            return
        }
        // The received Volume keeps its bytes of the in-flight budget until
        // the request resolves.
        pending.assemblies[peer] = nil
        pending.receivedBytes += assembly.totalBytes
        pending.receivedRoots.insert(rootCID)
        pending.volumes.append(AttributedVolumeResponse(
            rootCID: rootCID,
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.cid, $0.data) }),
            servedBy: peer))
        pendingVolumeRequests[requestID] = pending
        if !pending.bundle { resolveVolumeRequest(requestID: requestID) }
    }

    mutating func handleVolumeBundleEnd(requestID: UInt64, from peer: PeerID, sessionID: Data?) {
        guard var pending = pendingVolumeRequests[requestID],
              pending.matches(peer: peer, sessionID: sessionID) else { return }
        guard pending.bundle, pending.assemblies[peer] == nil else {
            rejectVolumeCandidate(requestID: requestID, peer: peer)
            return
        }
        pending.noBundle = pending.volumes.isEmpty
        pending.ended = true
        pendingVolumeRequests[requestID] = pending
        markVolumeCandidateDone(requestID: requestID, peer: peer)
    }

    mutating func markVolumeCandidateDone(
        requestID: UInt64,
        peer: PeerID,
        failure: VolumeFetchFailure? = nil
    ) {
        guard var pending = pendingVolumeRequests[requestID],
              pending.candidateSessions.removeValue(forKey: peer) != nil else { return }
        if failure == .localCapacityUnavailable || pending.failure == nil {
            pending.failure = failure
        }
        releaseVolumeAssembly(pending.assemblies.removeValue(forKey: peer))
        pendingVolumeRequests[requestID] = pending
        if pending.candidateSessions.isEmpty {
            resolveVolumeRequest(requestID: requestID)
        }
    }

    private mutating func rejectVolumeCandidate(requestID: UInt64, peer: PeerID) {
        ledger.recordProtocolViolation(peer: peer)
        markVolumeCandidateDone(requestID: requestID, peer: peer)
    }

    private mutating func releaseVolumeAssembly(_ assembly: VolumeAssembly?) {
        guard let assembly else { return }
        precondition(assembly.receivedBytes <= inFlightVolumeBytes)
        precondition(assembly.totalBytes <= reservedVolumeBytes)
        inFlightVolumeBytes -= assembly.receivedBytes
        reservedVolumeBytes -= assembly.totalBytes
    }

    /// The request's deadline passed: peers asked that completed no Volume
    /// count a timeout, so the next fetch tries them after peers that answer.
    mutating func timeOutVolumeRequest(requestID: UInt64) {
        if let pending = pendingVolumeRequests[requestID], pending.volumes.isEmpty {
            for peer in pending.candidateSessions.keys {
                volumeTimeoutStreaks[peer, default: 0] += 1
            }
        }
        resolveVolumeRequest(requestID: requestID)
    }

    mutating func resolveVolumeRequest(requestID: UInt64) {
        guard let pending = pendingVolumeRequests.removeValue(forKey: requestID) else { return }
        timers.cancel(.volumeRequest(requestID))
        if let servedBy = pending.volumes.first?.servedBy { volumeTimeoutStreaks[servedBy] = nil }
        for assembly in pending.assemblies.values { releaseVolumeAssembly(assembly) }
        precondition(pending.receivedBytes <= inFlightVolumeBytes)
        precondition(pending.receivedBytes <= reservedVolumeBytes)
        inFlightVolumeBytes -= pending.receivedBytes
        reservedVolumeBytes -= pending.receivedBytes
        volumeAskFinished(pending.fetch, requestID: requestID, pending.response)
    }

    // MARK: - Candidate selection

    /// The caller found content from `peer` deficient after validating it.
    /// The peer is passed over for that root for a while; nothing else changes.
    mutating func reportDeficientContent(rootCID: String, servedBy peer: PeerID) {
        guard MessageLimits.accepts(rootCID) else { return }
        forgetProvider(rootCID: rootCID, peer: peer)
        if deficientPeerSuppression[rootCID] == nil,
           deficientPeerSuppression.count >= Self.maxDeficiencySuppressionRoots,
           let evicted = deficientPeerSuppression.min(by: { left, right in
               let leftExpiry = left.value.values.max()
               let rightExpiry = right.value.values.max()
               if leftExpiry == rightExpiry { return left.key < right.key }
               return leftExpiry.map { expiry in
                   rightExpiry.map { expiry < $0 } ?? false
               } ?? true
           })?.key {
            deficientPeerSuppression.removeValue(forKey: evicted)
        }
        var peers = deficientPeerSuppression[rootCID] ?? [:]
        if peers[peer.publicKey] == nil,
           peers.count >= config.kBucketSize,
           let evicted = peers.min(by: { left, right in
               left.value == right.value ? left.key < right.key : left.value < right.value
           })?.key {
            peers.removeValue(forKey: evicted)
        }
        peers[peer.publicKey] = now.uptime + Self.deficiencySuppressionWindow
        deficientPeerSuppression[rootCID] = peers
    }

    mutating func isDeficiencySuppressed(rootCID: String, peer: PeerID) -> Bool {
        guard var byPeer = deficientPeerSuppression[rootCID] else { return false }
        if let until = byPeer[peer.publicKey], now.uptime < until { return true }
        byPeer = byPeer.filter { now.uptime < $0.value }
        deficientPeerSuppression[rootCID] = byPeer.isEmpty ? nil : byPeer
        return false
    }

    /// Connected peers in key order, rotated so successive fetches start
    /// with different ones.
    mutating func connectedFallbackCandidates(rootCID: String) -> [PeerID] {
        var eligible: [PeerID] = []
        for peer in connectedEndpointPeers.sorted(by: { $0.publicKey < $1.publicKey })
            where !isDeficiencySuppressed(rootCID: rootCID, peer: peer) {
            eligible.append(peer)
        }
        guard !eligible.isEmpty else { return [] }
        let start = nextConnectedFallbackOffset % eligible.count
        let rotated = Array(eligible[start...] + eligible[..<start])
        let selected = Array(rotated.prefix(config.maxContentCandidates))
        nextConnectedFallbackOffset = (start + selected.count) % eligible.count
        return selected
    }
}
