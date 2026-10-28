#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

struct PendingNeighborResponse: Sendable {
    let peer: PeerID
    let lookup: OpID
}

enum LookupWaiter: Sendable, Equatable {
    case request(RequestID)
    /// The periodic routing refresh.
    case refresh
    case providerSearch(OpID)
}

/// One iterative `findNode`: the candidates found so far, who has been
/// asked, the round, and what is outstanding. Connect results, answers and
/// deadlines advance it.
struct NodeLookup: Sendable {
    let id: OpID
    let targetHash: [UInt8]
    let waiter: LookupWaiter
    var candidatesByKey: [String: Router.BucketEntry] = [:]
    var routesByKey: [String: [LookupRoute]] = [:]
    var queried: Set<String> = []
    var round = 0
    var batch: [Router.BucketEntry] = []
    /// Set while a phase is still starting its work, so work that ends at
    /// once cannot end the phase early.
    var starting = false
    var connecting: [String: OpID?] = [:]
    var failedConnections: Set<String> = []
    var awaiting: Set<UInt64> = []
    var responses: [(PeerID, [PeerEndpoint])] = []
}

extension IvyCore {
    // MARK: - Message dispatch

    mutating func handleMessage(_ message: Message, from ref: SessionRef) {
        guard let session = session(ref) else { return }
        let peer = ref.key.peerID
        if case .pong(let nonce) = message {
            recordHealthActivity(session, pong: nonce)
        } else {
            recordHealthActivity(session)
        }
        if !config.mode.usesOverlayServices {
            switch message {
            case .ping, .pong, .peerMessage:
                break
            case .contentUnavailable,
                 .volumeRequest, .volumeChunk, .volumeBundleRequest, .volumeBundleEnd:
                guard config.privateContentExchangeEnabled else { return }
            default:
                return
            }
        }
        let sessionID = session.sessionID.bytes
        switch message {
        case .ping(let nonce):
            fireToPeer(peer, .pong(nonce: nonce))

        case .pong, .relayOpen, .relayOffer, .relayAccept, .relayReady, .relayPacket, .relayClose:
            return

        case .findNode(let target, let nonce):
            let closest = router.closestPeers(to: Array(target), count: config.kBucketSize)
            fireToPeer(peer, .neighbors(closest.map(\.endpoint), nonce: nonce))

        case .neighbors(let endpoints, let nonce):
            guard pendingNeighborResponses[nonce]?.peer == peer else { return }
            var accepted: [PeerEndpoint] = []
            for endpoint in endpoints {
                guard isAcceptableDiscoveredEndpoint(
                        endpoint, provenance: .referral("neighbors"), from: peer),
                      let key = try? PeerKey(endpoint.publicKey) else { continue }
                accepted.append(PeerEndpoint(
                    publicKey: key.hex,
                    host: endpoint.host.trimmingWhitespace(),
                    port: endpoint.port))
            }
            resolveNeighborResponse(nonce: nonce, endpoints: accepted)

        case .contentUnavailable(let requestID):
            handleContentUnavailable(requestID: requestID, from: peer, sessionID: sessionID)

        case .volumeRequest(let requestID, let rootCID):
            beginVolumeRequest(requestID: requestID, rootCID: rootCID, bundle: false, from: ref)

        case .volumeBundleRequest(let requestID, let rootCID):
            beginVolumeRequest(requestID: requestID, rootCID: rootCID, bundle: true, from: ref)

        case .volumeBundleEnd(let requestID):
            handleVolumeBundleEnd(requestID: requestID, from: peer, sessionID: sessionID)

        case let .volumeChunk(requestID, rootCID, index, count, totalEntries, totalBytes, payload):
            handleVolumeChunk(
                requestID: requestID,
                rootCID: rootCID,
                index: index,
                count: count,
                totalEntries: totalEntries,
                totalBytes: totalBytes,
                payload: payload,
                from: peer,
                sessionID: sessionID,
                relayed: links[ref.link]?.isDirect == false)

        case .findProviders(let rootCID, let requestID):
            handleFindProviders(rootCID: rootCID, requestID: requestID, from: peer)

        case .providers(let rootCID, let requestID, let records):
            handleProvidersResponse(
                rootCID: rootCID, requestID: requestID, records: records, from: peer)

        case .announceProvider(let rootCID, let expiresAt):
            handleAnnounceProvider(rootCID: rootCID, expiresAt: expiresAt, from: peer)

        case .peerMessage(let topic, let payload):
            // The link's next record waits for the application to finish
            // with this one: its pace bounds what Ivy takes from the peer.
            let token = blockForDelivery(ref.link)
            emit(.deliver(
                token,
                authenticatedPeer(session),
                PeerMessage(topic: topic, payload: payload)))
        }
    }

    /// Ends everything in flight that depended on `peer`'s endpoint session.
    mutating func cleanupPendingForPeer(_ peer: PeerID) {
        volumeTimeoutStreaks[peer] = nil
        volumeMissedPeers.remove(peer)
        for request in serving.keys.filter({ $0.peer == peer }).sorted(by: Self.servingOrder) {
            cancelServing(request)
        }
        for requestID in pendingVolumeRequests.keys.sorted()
            where pendingVolumeRequests[requestID]?.candidateSessions[peer] != nil {
            markVolumeCandidateDone(requestID: requestID, peer: peer)
        }
        for nonce in pendingNeighborResponses.keys.sorted()
            where pendingNeighborResponses[nonce]?.peer == peer {
            resolveNeighborResponse(nonce: nonce, endpoints: [])
        }
        let peerKey = peer.publicKey
        for rootCID in pendingProviderQueries.keys.sorted() {
            guard var pending = pendingProviderQueries[rootCID],
                  pending.expectedPeers.remove(peerKey) != nil else { continue }
            pendingProviderQueries[rootCID] = pending
            if pending.expectedPeers.isEmpty {
                resolveProviderQuery(rootCID: rootCID, requestID: pending.requestID)
            }
        }
    }

    // MARK: - Lookups

    @discardableResult
    mutating func startLookup(target: String, waiter: LookupWaiter) -> OpID {
        let id = makeID()
        lookups[id] = NodeLookup(id: id, targetHash: Router.hash(target), waiter: waiter)
        if case .request(let request) = waiter { requests[request] = .lookup(id) }
        runLookupRound(id)
        return id
    }

    private mutating func mergeRouterCandidates(into lookup: inout NodeLookup) {
        for entry in router.closestPeers(to: lookup.targetHash, count: config.kBucketSize) {
            let key = entry.id.publicKey
            lookup.candidatesByKey[key] = entry
            let preferred = hasEndpointSession(entry.id) ? entry.endpoint : nil
            lookup.routesByKey[key] = selectedLookupRoutes(
                [LookupRoute(endpoint: entry.endpoint, source: .authenticated)]
                    + (lookup.routesByKey[key] ?? []),
                preferred: preferred,
                maxRoutesPerIdentity: config.maxRoutesPerIdentity)
        }
    }

    func closestCandidateEntries(
        _ entries: some Sequence<Router.BucketEntry>,
        to targetHash: [UInt8]
    ) -> [Router.BucketEntry] {
        // Ties cannot occur between distinct keys, so the order is total.
        Array(entries)
            .sorted { Router.isCloser($0.hash, than: $1.hash, to: targetHash) }
            .prefix(config.kBucketSize)
            .map { $0 }
    }

    /// One round: connect to the closest candidates not yet asked, then ask them.
    private mutating func runLookupRound(_ id: OpID) {
        guard var lookup = lookups[id] else { return }
        guard isRunning else { return finishLookup(id, cancelled: true) }
        guard lookup.round < max(1, config.kBucketSize) else { return completeLookup(id) }
        lookup.round += 1
        mergeRouterCandidates(into: &lookup)

        let parallelism = min(Self.kademliaLookupParallelism, max(1, config.kBucketSize))
        let batch = Array(closestCandidateEntries(lookup.candidatesByKey.values, to: lookup.targetHash)
            .filter { !lookup.queried.contains($0.id.publicKey) }
            .prefix(parallelism))
        guard !batch.isEmpty else {
            lookups[id] = lookup
            return completeLookup(id)
        }
        for entry in batch { lookup.queried.insert(entry.id.publicKey) }
        lookup.batch = batch
        lookup.failedConnections = []
        lookup.connecting = [:]
        lookup.starting = true

        var dials: [(key: String, routes: [PeerEndpoint])] = []
        for entry in batch where !hasEndpointSession(entry.id) {
            let key = entry.id.publicKey
            let selected = selectedLookupRoutes(
                lookup.routesByKey[key] ?? [],
                preferred: nil,
                maxRoutesPerIdentity: config.maxRoutesPerIdentity)
            lookup.routesByKey[key] = selected
            dials.append((key, selected.isEmpty ? [entry.endpoint] : selected.map(\.endpoint)))
            lookup.connecting[key] = .some(nil)
        }
        lookups[id] = lookup

        for dial in dials {
            let op = startConnect(
                to: dial.routes, role: .endpoint, relayOnly: false, waiter: .lookup(id, key: dial.key))
            if let op, lookups[id]?.connecting[dial.key] != nil {
                lookups[id]?.connecting[dial.key] = .some(op)
            }
        }
        guard lookups[id] != nil else { return }
        lookups[id]?.starting = false
        if lookups[id]?.connecting.isEmpty == true { queryLookupBatch(id) }
    }

    mutating func lookupConnectFinished(_ id: OpID, key: String, failed: Bool) {
        guard var lookup = lookups[id], lookup.connecting.removeValue(forKey: key) != nil else {
            return
        }
        if failed { lookup.failedConnections.insert(key) }
        lookups[id] = lookup
        if lookup.connecting.isEmpty, !lookup.starting { queryLookupBatch(id) }
    }

    private mutating func queryLookupBatch(_ id: OpID) {
        guard var lookup = lookups[id] else { return }
        guard isRunning else { return finishLookup(id, cancelled: true) }
        for key in lookup.failedConnections.sorted() {
            let peer = PeerID(publicKey: key)
            guard !hasEndpointSession(peer) else { continue }
            router.removePeer(peer)
            lookup.candidatesByKey.removeValue(forKey: key)
            lookup.routesByKey.removeValue(forKey: key)
        }
        lookup.failedConnections = []
        lookup.responses = []
        lookup.awaiting = []
        lookup.starting = true
        lookups[id] = lookup

        for entry in lookup.batch where hasEndpointSession(entry.id) {
            guard pendingNeighborResponses.count < config.maxPendingRequests else { continue }
            let nonce = makeWireOperationID(avoiding: Set(pendingNeighborResponses.keys))
            pendingNeighborResponses[nonce] = PendingNeighborResponse(peer: entry.id, lookup: id)
            guard case .enqueued = fireToPeer(
                entry.id, .findNode(target: Data(lookup.targetHash), nonce: nonce)) else {
                pendingNeighborResponses.removeValue(forKey: nonce)
                continue
            }
            timers.set(.neighbor(nonce), at: now.uptime + Self.lookupResponseTimeout)
            lookups[id]?.awaiting.insert(nonce)
        }
        lookups[id]?.starting = false
        if lookups[id]?.awaiting.isEmpty == true { mergeLookupResponses(id) }
    }

    mutating func resolveNeighborResponse(nonce: UInt64, endpoints: [PeerEndpoint]) {
        guard let pending = pendingNeighborResponses.removeValue(forKey: nonce) else { return }
        timers.cancel(.neighbor(nonce))
        guard var lookup = lookups[pending.lookup], lookup.awaiting.remove(nonce) != nil else {
            return
        }
        if !endpoints.isEmpty { lookup.responses.append((pending.peer, endpoints)) }
        lookups[pending.lookup] = lookup
        if lookup.awaiting.isEmpty, !lookup.starting { mergeLookupResponses(pending.lookup) }
    }

    private func authenticatedRoutes() -> [String: PeerEndpoint] {
        Dictionary(uniqueKeysWithValues: router.allPeers()
            .filter { hasEndpointSession($0.id) }
            .map { ($0.id.publicKey, $0.endpoint) })
    }

    private mutating func mergeLookupResponses(_ id: OpID) {
        guard var lookup = lookups[id] else { return }
        guard isRunning else { return finishLookup(id, cancelled: true) }
        let preferredRoutes = authenticatedRoutes()
        for (source, endpoints) in lookup.responses.sorted(by: { $0.0.publicKey < $1.0.publicKey }) {
            for endpoint in endpoints {
                let peer = PeerID(publicKey: endpoint.publicKey)
                let key = peer.publicKey
                if lookup.candidatesByKey[key] == nil {
                    lookup.candidatesByKey[key] = Router.BucketEntry(
                        id: peer, hash: Router.hash(key), endpoint: endpoint)
                }
                let oldRoutes = lookup.routesByKey[key] ?? []
                let newRoutes = selectedLookupRoutes(
                    oldRoutes + [LookupRoute(endpoint: endpoint, source: .referral(source.publicKey))],
                    preferred: preferredRoutes[key],
                    maxRoutesPerIdentity: config.maxRoutesPerIdentity)
                lookup.routesByKey[key] = newRoutes
                // A peer that could not be reached is tried again on a new route.
                if !hasEndpointSession(peer), newRoutes != oldRoutes {
                    lookup.queried.remove(key)
                }
            }
        }
        lookup.responses = []
        let retained = Set(closestCandidateEntries(
            lookup.candidatesByKey.values, to: lookup.targetHash).map { $0.id.publicKey })
        lookup.candidatesByKey = lookup.candidatesByKey.filter { retained.contains($0.key) }
        lookup.routesByKey = lookup.routesByKey.filter { retained.contains($0.key) }
        lookups[id] = lookup
        runLookupRound(id)
    }

    private mutating func completeLookup(_ id: OpID) {
        guard var lookup = lookups[id] else { return }
        mergeRouterCandidates(into: &lookup)
        let currentRoutes = authenticatedRoutes()
        let result = closestCandidateEntries(
            lookup.candidatesByKey.values, to: lookup.targetHash
        ).map { entry -> PeerEndpoint in
            let key = entry.id.publicKey
            let selected = selectedLookupRoutes(
                lookup.routesByKey[key] ?? [],
                preferred: currentRoutes[key],
                maxRoutesPerIdentity: config.maxRoutesPerIdentity)
            return currentRoutes[key] ?? selected.first?.endpoint ?? entry.endpoint
        }
        lookups[id] = lookup
        finishLookup(id, result: result)
    }

    /// Ends a lookup early; its waiter hears an empty answer.
    mutating func finishLookup(_ id: OpID, cancelled: Bool) {
        finishLookup(id, result: [])
    }

    private mutating func finishLookup(_ id: OpID, result: [PeerEndpoint]) {
        guard let lookup = lookups.removeValue(forKey: id) else { return }
        for key in lookup.connecting.keys.sorted() {
            if let op = lookup.connecting[key] ?? nil { cancelConnectOp(op) }
        }
        for nonce in lookup.awaiting.sorted() {
            pendingNeighborResponses.removeValue(forKey: nonce)
            timers.cancel(.neighbor(nonce))
        }
        switch lookup.waiter {
        case .request(let request):
            complete(request, .endpoints(result))
        case .refresh:
            if isRunning, config.mode.participatesInPublicDiscovery {
                timers.set(.routingRefresh, at: now.uptime + config.routingRefreshInterval)
            }
        case .providerSearch(let search):
            providerSearchLookupFinished(search)
        }
    }

    /// Looks up a random key, which refreshes the buckets it passes through.
    mutating func refreshRoutingTable() {
        guard isRunning, case .overlay = config.mode else { return }
        let target = random.bytes32().map { hexByte($0) }.joined()
        startLookup(target: target, waiter: .refresh)
    }

    mutating func makeWireOperationID(avoiding inUse: Set<UInt64>) -> UInt64 {
        repeat {
            nextWireOperationID &+= 1
        } while nextWireOperationID == 0 || inUse.contains(nextWireOperationID)
        return nextWireOperationID
    }
}
