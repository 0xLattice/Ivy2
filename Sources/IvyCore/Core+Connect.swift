import Foundation
import Tally

/// Who is told how a connect operation ended.
enum ConnectWaiter: Sendable, Equatable {
    case request(RequestID)
    /// Upkeep of a configured peer: a miss schedules a reconnect.
    case maintain
    case lookup(OpID, key: String)
    case group(OpID)
}

enum ConnectResult: Sendable, Equatable {
    case connected
    /// A session, dial or handshake for the peer already holds its place,
    /// or there is no room: nothing was tried.
    case notAdmitted
    case failed(IvyError)
    case cancelled
}

/// A dial the shell is making. It holds connection capacity from the moment
/// it is asked for until the shell reports how it ended.
struct OutgoingDial: Sendable {
    var endpoint: PeerEndpoint
    let dial: DialID
    var op: OpID?
    var link: LinkID?
    /// `disconnect` named this peer while the dial was out.
    var cancelled = false
    /// The run that asked for the dial has stopped.
    var abandoned = false
}

/// A connection the shell established itself and handed to a connect
/// operation, in place of one the core would have asked it to dial.
struct SuppliedConnection: Sendable {
    let connection: ConnectionID
    let observedHost: String?
    let localHost: String?
}

/// One attempt to reach a peer: each direct route in turn, then each carrier.
struct ConnectOp: Sendable {
    enum Phase: Sendable {
        case idle
        case dialing
        case authenticating(LinkID)
        case awaitingResponder(AfterResponder)
        case relayOpening(routeID: Data)
        case relayAuthenticating(routeID: Data, link: LinkID)
    }

    /// What was being decided when a competing inbound handshake was found.
    enum AfterResponder: Sendable {
        case dialFailed
        case bindFailed
        case authenticated
    }

    let id: OpID
    let key: PeerKey
    let role: AuthenticatedPeerRole
    let waiter: ConnectWaiter
    /// The endpoint the caller named first; a relayed session is recorded under it.
    let endpoint: PeerEndpoint
    /// Direct routes not yet tried.
    var routes: [PeerEndpoint]
    /// Set when the caller supplied the connection: it is the only route,
    /// and there is no falling back to a carrier.
    var supplied: SuppliedConnection?
    var carriers: [PeerKey] = []
    var phase: Phase = .idle

    var peer: PeerID { key.peerID }
}

enum GroupWaiter: Sendable, Equatable {
    case volumeFetch(OpID)
}

/// Connect operations run side by side for one fetch.
struct ConnectGroup: Sendable {
    var outstanding: Set<OpID> = []
    let waiter: GroupWaiter
    var building = true
}

extension IvyCore {
    // MARK: - Starting

    /// Starts reaching the peer `routes` name. Returns the operation while it
    /// is still running; nil when it ended at once (its waiter has been told).
    @discardableResult
    mutating func startConnect(
        to routes: [PeerEndpoint],
        role: AuthenticatedPeerRole,
        relayOnly: Bool,
        waiter: ConnectWaiter,
        over supplied: SuppliedConnection? = nil
    ) -> OpID? {
        func refuse(_ error: IvyError, peer: PeerID?) -> OpID? {
            if let supplied { emit(.close(supplied.connection)) }
            resolveConnectWaiter(waiter, .failed(error), peer: peer, role: role)
            return nil
        }
        guard let endpoint = routes.first,
              let key = try? PeerKey(endpoint.publicKey),
              routes.allSatisfy({ (try? PeerKey($0.publicKey)) == key }) else {
            return refuse(.invalidPeerKey, peer: nil)
        }
        let allowed = role == .carrier ? config.isConfiguredCarrier(key) : config.allowsEndpoint(key)
        guard allowed else { return refuse(.peerOutsideMode, peer: key.peerID) }
        guard isRunning else { return refuse(.notRunning, peer: key.peerID) }
        if let supplied, (supplied.observedHost ?? "").isEmpty {
            return refuse(.streamHasNoObservedHost, peer: key.peerID)
        }

        let id = makeID()
        connectOps[id] = ConnectOp(
            id: id, key: key, role: role, waiter: waiter, endpoint: endpoint, routes: routes,
            supplied: supplied)
        if case .request(let request) = waiter { requests[request] = .connect(id) }
        if relayOnly {
            beginRelay(id)
        } else {
            tryNextRoute(id)
        }
        return connectOps[id] == nil ? nil : id
    }

    mutating func maintainConfiguredConnection(peer key: PeerKey, role: AuthenticatedPeerRole) {
        guard isRunning, !reconnectSuppressed.contains(key.peerID) else { return }
        startConnect(
            to: configuredEndpoints(for: key, role: role),
            role: role,
            relayOnly: false,
            waiter: .maintain)
    }

    private mutating func finishConnect(_ id: OpID, _ result: ConnectResult) {
        guard let op = connectOps.removeValue(forKey: id) else { return }
        if responderWaiters[op.key] == id { responderWaiters.removeValue(forKey: op.key) }
        closeSuppliedConnectionUnlessSelected(op)
        resolveConnectWaiter(op.waiter, result, peer: op.peer, role: op.role, op: id)
    }

    /// A supplied connection is the caller's only as the peer's session.
    private mutating func closeSuppliedConnectionUnlessSelected(_ op: ConnectOp) {
        guard let supplied = op.supplied else { return }
        if let link = linkByConnection[supplied.connection] {
            if sessions[op.key]?.link != link { removeLink(link, notifyTransport: true) }
        } else {
            emit(.close(supplied.connection))
        }
    }

    /// Ends an operation from outside (stop): its waiter hears `cancelled`.
    mutating func finishConnectOp(_ id: OpID, _ result: ConnectResult) {
        finishConnect(id, result)
    }

    private mutating func resolveConnectWaiter(
        _ waiter: ConnectWaiter,
        _ result: ConnectResult,
        peer: PeerID?,
        role: AuthenticatedPeerRole,
        op: OpID? = nil
    ) {
        switch waiter {
        case .request(let request):
            let outcome: ConnectOutcome
            switch result {
            case .connected:
                outcome = .connected
            case .notAdmitted:
                let key = peer.flatMap { try? PeerKey($0.publicKey) }
                let inProgress = peer.map { outgoingDials[$0] != nil } ?? false
                    || key.map { responderWaiters[$0] != nil } ?? false
                outcome = .failed(inProgress ? .connectionInProgress : .identityVerificationFailed)
            case .failed(let error):
                outcome = .failed(error)
            case .cancelled:
                outcome = .cancelled
            }
            complete(request, .connect(outcome))
        case .maintain:
            if result != .connected, let peer { scheduleReconnect(peer: peer, role: role) }
        case .lookup(let lookup, let key):
            var failed = false
            if case .failed = result { failed = true }
            lookupConnectFinished(lookup, key: key, failed: failed)
        case .group(let group):
            if let op { connectGroupMemberFinished(group, op: op) }
        }
    }

    // MARK: - Direct routes

    private mutating func tryNextRoute(_ id: OpID) {
        while var op = connectOps[id] {
            let peer = op.peer
            guard !op.routes.isEmpty else {
                // Every direct route failed.
                if op.role == .carrier || op.supplied != nil {
                    return finishConnect(id, .failed(.identityVerificationFailed))
                }
                guard config.mode.usesOverlayServices else {
                    return finishConnect(id, .failed(.noRelayAvailable))
                }
                return beginRelay(id)
            }
            let route = op.routes.removeFirst()
            op.phase = .idle
            connectOps[id] = op

            let hasSession = sessions[op.key]?.role == op.role && hasLiveSession(op.key)
            if reconnectSuppressed.contains(peer) {
                if op.role == .carrier { continue }
                return finishConnect(id, .notAdmitted)
            }
            if hasSession { return finishConnect(id, .connected) }
            guard let dial = reserveOutgoingDial(
                to: route, key: op.key, op: id, dialling: op.supplied == nil) else {
                if op.role == .carrier { continue }
                return finishConnect(id, .notAdmitted)
            }
            connectOps[id]?.phase = .dialing
            if let supplied = op.supplied {
                // The shell already holds the connection: it stands in for
                // the dial's answer. Its address is not one Ivy can dial, so
                // it is kept out of the link's endpoint and so out of routing.
                dialSucceeded(
                    dial,
                    connection: supplied.connection,
                    observedHost: supplied.observedHost,
                    localHost: supplied.localHost,
                    linkEndpoint: PeerEndpoint(publicKey: op.key.hex, host: "unknown", port: 0))
            }
            return
        }
    }

    /// Takes connection capacity for a dial and asks the shell to make it.
    mutating func reserveOutgoingDial(
        to endpoint: PeerEndpoint,
        key: PeerKey,
        op: OpID?,
        dialling: Bool = true
    ) -> DialID? {
        let peer = key.peerID
        guard sessions[key] == nil,
              outgoingDials[peer] == nil,
              responderWaiters[key] == nil,
              connectionCapacityUsed < config.maxConnections,
              directConnectionCount(inNetgroup: NetGroup.group(endpoint.host))
                < config.maxConnectionsPerNetgroup else { return nil }
        let dial = DialID(makeID())
        let canonical = PeerEndpoint(publicKey: key.hex, host: endpoint.host, port: endpoint.port)
        outgoingDials[peer] = OutgoingDial(endpoint: canonical, dial: dial, op: op)
        dialPeers[dial] = peer
        if dialling { emit(.dial(dial, canonical)) }
        return dial
    }

    mutating func dialFailed(_ dial: DialID) {
        guard let peer = dialPeers.removeValue(forKey: dial),
              let entry = outgoingDials[peer], entry.dial == dial else { return }
        if entry.abandoned {
            // The run that asked has stopped. A newer run whose own attempt
            // this dial was blocking gets its configured reconnect.
            finishOutgoingDial(to: peer)
            return
        }
        let connected = finishOutgoingDial(to: peer)
        guard let op = entry.op, connectOps[op] != nil else { return }
        awaitCompetingResponder(op, alreadyConnected: connected, then: .dialFailed)
    }

    mutating func dialSucceeded(
        _ dial: DialID,
        connection: ConnectionID,
        observedHost: String?,
        localHost: String?,
        linkEndpoint: PeerEndpoint? = nil
    ) {
        guard let peer = dialPeers[dial],
              var entry = outgoingDials[peer], entry.dial == dial,
              let key = try? PeerKey(peer.publicKey) else {
            emit(.close(connection))
            return
        }
        if entry.abandoned {
            emit(.close(connection))
            finishOutgoingDial(to: peer)
            return
        }
        let link = makeLink(
            .direct(connection),
            endpoint: linkEndpoint ?? entry.endpoint,
            observedHost: observedHost,
            localHost: localHost)
        entry.link = link
        if let observedHost, !observedHost.isEmpty {
            entry.endpoint = PeerEndpoint(
                publicKey: entry.endpoint.publicKey,
                host: observedHost,
                port: entry.endpoint.port)
        }
        outgoingDials[peer] = entry
        let op = entry.op.flatMap { connectOps[$0] == nil ? nil : $0 }

        // The address the socket reached decides the netgroup, not the one dialled.
        guard directConnectionCount(inNetgroup: NetGroup.group(entry.endpoint.host))
                <= config.maxConnectionsPerNetgroup else {
            removeLink(link, notifyTransport: true)
            let connected = finishOutgoingDial(to: peer)
            if let op { awaitCompetingResponder(op, alreadyConnected: connected, then: .bindFailed) }
            return
        }
        guard isRunning, let op, !entry.cancelled, !reconnectSuppressed.contains(peer) else {
            finishOutgoingDial(to: peer)
            removeLink(link, notifyTransport: true)
            if let op { finishConnect(op, .cancelled) }
            return
        }
        connectOps[op]?.phase = .authenticating(link)
        syncReading(link)
        authenticateInitiator(link, expected: key, routeBinding: Self.directRouteBinding, op: op)
    }

    /// Releases the dial's capacity. True when the peer ended up connected,
    /// by this dial or by a competing one.
    @discardableResult
    mutating func finishOutgoingDial(to peer: PeerID) -> Bool {
        guard let entry = outgoingDials.removeValue(forKey: peer) else { return false }
        dialPeers.removeValue(forKey: entry.dial)
        let key = try? PeerKey(peer.publicKey)
        if isRunning, let key, hasLiveSession(key) {
            reconnectAttempts.removeValue(forKey: peer)
            cancelScheduledReconnect(peer)
            return true
        }
        if isRunning, let key {
            let role: AuthenticatedPeerRole = config.isConfiguredCarrier(key) ? .carrier : .endpoint
            if !configuredEndpoints(for: key, role: role).isEmpty {
                scheduleReconnect(peer: peer, role: role)
            }
        }
        return false
    }

    /// The handshake `op` was waiting on has ended.
    mutating func authenticationFinished(_ id: OpID, authenticated: Bool) {
        guard let op = connectOps[id] else { return }
        switch op.phase {
        case .authenticating:
            // Whichever handshake won, the peer is connected or it is not.
            let connected = finishOutgoingDial(to: op.peer)
            awaitCompetingResponder(id, alreadyConnected: connected, then: .authenticated)
        case .relayAuthenticating(let routeID, let link):
            guard isRunning, !reconnectSuppressed.contains(op.peer) else {
                removeLink(link, notifyTransport: true)
                return finishConnect(id, .cancelled)
            }
            if authenticated, hasLiveSession(op.key) { return finishConnect(id, .connected) }
            closeInstalledRoute(routeID, notifyCarrier: true)
            tryNextCarrier(id)
        default:
            return
        }
    }

    // MARK: - Simultaneous dials

    /// Two peers dialling each other each see an inbound handshake compete
    /// with their own dial. When this side's attempt ends without a session,
    /// a verified inbound handshake for the same peer decides the outcome.
    private mutating func awaitCompetingResponder(
        _ id: OpID,
        alreadyConnected: Bool,
        then: ConnectOp.AfterResponder
    ) {
        guard let op = connectOps[id] else { return }
        if alreadyConnected { return responderResolved(id, connected: true, then: then) }
        guard isRunning, !reconnectSuppressed.contains(op.peer) else {
            return responderResolved(id, connected: false, then: then)
        }
        if hasLiveSession(op.key) { return responderResolved(id, connected: true, then: then) }
        guard responderWaiters[op.key] == nil, hasVerifiedResponder(for: op.key) else {
            return responderResolved(id, connected: false, then: then)
        }
        responderWaiters[op.key] = id
        connectOps[id]?.phase = .awaitingResponder(then)
    }

    private mutating func responderResolved(
        _ id: OpID,
        connected: Bool,
        then: ConnectOp.AfterResponder
    ) {
        guard let op = connectOps[id] else { return }
        guard isRunning else { return finishConnect(id, .failed(.notRunning)) }
        if connected { return finishConnect(id, .connected) }
        guard !reconnectSuppressed.contains(op.peer) else { return finishConnect(id, .cancelled) }
        switch then {
        case .dialFailed, .authenticated:
            tryNextRoute(id)
        case .bindFailed:
            if op.role == .carrier { tryNextRoute(id) } else { finishConnect(id, .notAdmitted) }
        }
    }

    func hasVerifiedResponder(for peer: PeerKey) -> Bool {
        pendingSessions.values.contains { pending in
            guard case .responder = pending.direction else { return false }
            return isLive(pending.link)
                && pending.remoteKey == peer
                && pending.sessionID != nil
                && pending.helloInitiator != nil
                && pending.helloResponder != nil
        }
    }

    mutating func updateResponderWaiter(for peer: PeerKey) {
        guard responderWaiters[peer] != nil else { return }
        if hasLiveSession(peer) {
            resolveResponderWaiter(for: peer, result: true)
        } else if !hasVerifiedResponder(for: peer) {
            resolveResponderWaiter(for: peer, result: false)
        }
    }

    mutating func resolveResponderWaiter(for peer: PeerKey, result: Bool) {
        guard let op = responderWaiters.removeValue(forKey: peer) else { return }
        responderResults.append((op, result))
    }

    mutating func responderFinished(_ id: OpID, connected: Bool) {
        guard case .awaitingResponder(let then) = connectOps[id]?.phase else { return }
        responderResolved(id, connected: connected, then: then)
    }

    // MARK: - Through a carrier

    private mutating func beginRelay(_ id: OpID) {
        guard let op = connectOps[id] else { return }
        guard config.mode.usesOverlayServices else {
            return finishConnect(id, .failed(.noRelayAvailable))
        }
        guard isRunning, !reconnectSuppressed.contains(op.peer) else {
            return finishConnect(id, .failed(.notRunning))
        }
        if endpointSession(for: op.key).map({ isLive($0.link) }) == true {
            return finishConnect(id, .connected)
        }
        connectOps[id]?.carriers = sessions.values
            .filter { $0.role == .carrier && links[$0.link]?.isDirect == true }
            .map(\.peerKey)
            .sorted()
        tryNextCarrier(id)
    }

    private mutating func tryNextCarrier(_ id: OpID) {
        while var op = connectOps[id] {
            guard isRunning, !reconnectSuppressed.contains(op.peer) else {
                return finishConnect(id, .cancelled)
            }
            guard !op.carriers.isEmpty else {
                return finishConnect(id, .failed(.noRelayAvailable))
            }
            let carrier = op.carriers.removeFirst()
            op.phase = .idle
            connectOps[id] = op
            guard let routeID = requestRelayRoute(target: op.key, via: carrier, op: id) else { continue }
            connectOps[id]?.phase = .relayOpening(routeID: routeID)
            return
        }
    }

    /// The carrier answered, refused or never replied to `relayOpen`.
    mutating func relayOpenFinished(_ id: OpID, routeID: Data, carrier: PeerKey, opened: Bool) {
        guard let op = connectOps[id],
              case .relayOpening(let opening) = op.phase, opening == routeID else {
            if opened { closeInstalledRoute(routeID, notifyCarrier: true) }
            return
        }
        guard opened else { return tryNextCarrier(id) }
        guard isRunning, !reconnectSuppressed.contains(op.peer) else {
            closeInstalledRoute(routeID, notifyCarrier: true)
            return finishConnect(id, .cancelled)
        }
        guard let link = openInstalledRouteLink(
            endpoint: PeerEndpoint(
                publicKey: op.key.hex,
                host: op.endpoint.host,
                port: op.endpoint.port),
            target: op.key,
            routeID: routeID,
            carrier: carrier) else {
            closeInstalledRoute(routeID, notifyCarrier: true)
            return tryNextCarrier(id)
        }
        connectOps[id]?.phase = .relayAuthenticating(routeID: routeID, link: link)
        authenticateInitiator(link, expected: op.key, routeBinding: routeID, op: id)
    }

    // MARK: - Cancelling

    /// Ends an operation whose caller has gone. A dial already out keeps its
    /// capacity until the shell reports it.
    mutating func cancelConnectOp(_ id: OpID) {
        guard let op = connectOps.removeValue(forKey: id) else { return }
        if responderWaiters[op.key] == id { responderWaiters.removeValue(forKey: op.key) }
        defer { closeSuppliedConnectionUnlessSelected(op) }
        switch op.phase {
        case .idle, .awaitingResponder:
            break
        case .dialing:
            outgoingDials[op.peer]?.op = nil
        case .authenticating(let link):
            cancelAuthentication(link)
            finishOutgoingDial(to: op.peer)
        case .relayOpening(let routeID):
            timeoutRelayOpen(routeID)
        case .relayAuthenticating(let routeID, let link):
            cancelAuthentication(link)
            closeInstalledRoute(routeID, notifyCarrier: true)
        }
        resolveConnectWaiter(op.waiter, .cancelled, peer: op.peer, role: op.role, op: id)
    }

    private mutating func cancelAuthentication(_ link: LinkID) {
        if pendingSessions[link] != nil {
            failPendingSession(link)
        } else if let key = sessionKeyByLink[link], let session = sessions[key], session.link == link {
            teardownSession(session.ref, reconnect: true)
            removeLink(link, notifyTransport: true)
        }
    }

    // MARK: - Groups

    /// Connects, side by side, to the providers named that have no session
    /// yet. Nil when there was nobody to wait for; otherwise the waiter hears
    /// when every attempt has ended.
    mutating func startConnectGroup(_ endpoints: [PeerEndpoint], waiter: GroupWaiter) -> OpID? {
        guard isRunning else { return nil }
        var alternativesByPeer: [String: [PeerEndpoint]] = [:]
        var peerOrder: [String] = []
        for endpoint in uniqueProviderEndpoints(endpoints) {
            if alternativesByPeer[endpoint.publicKey] == nil { peerOrder.append(endpoint.publicKey) }
            alternativesByPeer[endpoint.publicKey, default: []].append(endpoint)
        }
        let candidates = Array(peerOrder.compactMap { key -> [PeerEndpoint]? in
            guard !hasEndpointSession(PeerID(publicKey: key)) else { return nil }
            return alternativesByPeer[key].map { Array($0.prefix(config.maxRoutesPerIdentity)) }
        }.prefix(config.maxContentCandidates))
        guard !candidates.isEmpty else { return nil }

        let id = makeID()
        connectGroups[id] = ConnectGroup(waiter: waiter)
        for alternatives in candidates {
            if let op = startConnect(
                to: alternatives, role: .endpoint, relayOnly: false, waiter: .group(id)) {
                connectGroups[id]?.outstanding.insert(op)
            }
        }
        connectGroups[id]?.building = false
        if connectGroups[id]?.outstanding.isEmpty == true {
            connectGroups.removeValue(forKey: id)
            return nil
        }
        return id
    }

    private mutating func connectGroupMemberFinished(_ id: OpID, op: OpID) {
        guard var group = connectGroups[id], group.outstanding.remove(op) != nil else { return }
        connectGroups[id] = group
        guard group.outstanding.isEmpty, !group.building else { return }
        connectGroups.removeValue(forKey: id)
        switch group.waiter {
        case .volumeFetch(let fetch):
            volumeFetchConnectGroupFinished(fetch, group: id)
        }
    }

    mutating func cancelConnectGroup(_ id: OpID) {
        guard let group = connectGroups.removeValue(forKey: id) else { return }
        for op in group.outstanding.sorted() { cancelConnectOp(op) }
    }

    // MARK: - Reconnecting

    mutating func scheduleReconnect(peer: PeerID, role: AuthenticatedPeerRole) {
        guard let key = try? PeerKey(peer.publicKey),
              isRunning,
              !reconnectSuppressed.contains(peer),
              sessions[key] == nil,
              outgoingDials[peer] == nil,
              reconnectScheduled[peer] == nil else { return }
        reconnectScheduled[peer] = role
        timers.set(.reconnect(peer), at: now.uptime + reconnectDelay(for: peer))
    }

    /// Exponential backoff from half a second to thirty, plus jitter.
    mutating func reconnectDelay(for peer: PeerID) -> Duration {
        let attempt = min((reconnectAttempts[peer] ?? 0) + 1, 16)
        reconnectAttempts[peer] = attempt
        let shift = min(attempt - 1, 10)
        let exponential = Self.reconnectBaseDelayMs * (UInt64(1) << UInt64(shift))
        let capped = min(exponential, Self.reconnectMaxDelayMs)
        return .milliseconds(Int64(capped + UInt64.random(in: 0 ... Self.reconnectJitterMs, using: &random)))
    }

    mutating func runScheduledReconnect(_ peer: PeerID) {
        guard let role = reconnectScheduled.removeValue(forKey: peer),
              isRunning,
              !reconnectSuppressed.contains(peer),
              let key = try? PeerKey(peer.publicKey) else { return }
        maintainConfiguredConnection(peer: key, role: role)
    }

    mutating func cancelScheduledReconnect(_ peer: PeerID) {
        guard reconnectScheduled.removeValue(forKey: peer) != nil else { return }
        timers.cancel(.reconnect(peer))
    }
}
