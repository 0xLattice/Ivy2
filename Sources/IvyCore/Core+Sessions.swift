import Foundation
import Tally

enum PendingSessionDirection: Sendable {
    case initiator(expected: PeerKey, routeBinding: Data)
    case responder
}

/// A link whose handshake has not finished. It is absent from routing,
/// deliveries, content and application messages.
struct PendingSession: Sendable {
    let link: LinkID
    let direction: PendingSessionDirection
    var helloInitiator: SignedSessionHelloInitiator?
    var helloResponder: SignedSessionHelloResponder?
    var sessionID: SessionID?
    var remoteKey: PeerKey?
    var remoteMetadata: PeerMetadata?
    /// The connect operation waiting on this handshake.
    var op: OpID?
}

/// Names one authenticated session exactly: a replacement for the same key
/// has a different link.
struct SessionRef: Sendable, Hashable {
    let key: PeerKey
    let link: LinkID
}

struct Session: Sendable {
    let link: LinkID
    let peerKey: PeerKey
    let role: AuthenticatedPeerRole
    let sessionID: SessionID
    let metadata: PeerMetadata
    var sequenceState = SessionSequenceState()
    var didNotifyConnect = false
    /// The connect operation waiting for the application to see this session.
    var op: OpID?

    var ref: SessionRef { SessionRef(key: peerKey, link: link) }
}

enum ProtocolViolationEvidence {
    case unverified
    case signedTransport
    case signedPayload
}

extension IvyCore {
    // MARK: - Lookup

    func endpointSession(for key: PeerKey) -> Session? {
        guard let session = sessions[key], session.role == .endpoint else { return nil }
        return session
    }

    func endpointSession(for peer: PeerID) -> Session? {
        guard let key = try? PeerKey(peer.publicKey) else { return nil }
        return endpointSession(for: key)
    }

    func carrierSession(for key: PeerKey) -> Session? {
        guard let session = sessions[key], session.role == .carrier else { return nil }
        return session
    }

    func session(_ ref: SessionRef) -> Session? {
        guard isCurrent(ref) else { return nil }
        return sessions[ref.key]
    }

    func isCurrent(_ ref: SessionRef) -> Bool {
        isRunning && sessions[ref.key]?.link == ref.link
    }

    func hasLiveSession(_ key: PeerKey) -> Bool {
        sessions[key].map { isLive($0.link) } ?? false
    }

    func hasEndpointSession(_ peer: PeerID) -> Bool {
        endpointSession(for: peer).map { isLive($0.link) } ?? false
    }

    func endpointLink(for peer: PeerID) -> Link? {
        endpointSession(for: peer).flatMap { links[$0.link] }
    }

    func authenticatedPeer(_ session: Session) -> AuthenticatedPeer {
        AuthenticatedPeer(
            key: session.peerKey,
            role: session.role,
            route: links[session.link]?.route ?? .direct,
            metadata: session.metadata,
            sessionID: session.sessionID.bytes)
    }

    static func attributedPeer(
        _ peer: PeerKey,
        direct: Bool,
        evidence: ProtocolViolationEvidence
    ) -> PeerKey? {
        switch evidence {
        case .unverified:
            return nil
        case .signedTransport:
            return direct ? peer : nil
        case .signedPayload:
            return peer
        }
    }

    /// Effective outbound frame size over a (possibly relayed) route: the peer's
    /// advertised accept, capped by the carrier connection's capacity on a relayed
    /// route so we never build a frame the carrier cannot forward.
    func effectiveOutboundFrameSize(for id: LinkID?) -> UInt32 {
        guard let id, let link = links[id] else { return IvyConfig.defaultProtocolMaxFrameSize }
        var limit = link.peerMaxFrameSize
        if case .relayed(_, let carrier) = link.transport,
           let carrierLink = directRelayCarrierSession(for: carrier).flatMap({ links[$0.link] }) {
            limit = min(limit, carrierLink.peerMaxFrameSize)
        }
        return limit
    }

    // MARK: - Capacity

    var unrepresentedOutgoingDials: [OutgoingDial] {
        outgoingDials.values.filter { dial in
            guard let link = dial.link else { return true }
            return pendingSessions[link] == nil && sessionKeyByLink[link] == nil
        }
    }

    var connectionCapacityUsed: Int {
        sessions.count + pendingSessions.count + unrepresentedOutgoingDials.count
    }

    func directConnectionCount(inNetgroup group: String) -> Int {
        let authenticated = sessions.values.lazy.filter {
            self.links[$0.link].map { $0.isDirect && self.linkNetgroup($0) == group } ?? false
        }.count
        let pending = pendingSessions.keys.lazy.filter {
            self.links[$0].map { $0.isDirect && self.linkNetgroup($0) == group } ?? false
        }.count
        let reserved = unrepresentedOutgoingDials.lazy.filter {
            NetGroup.group($0.endpoint.host) == group
        }.count
        return authenticated + pending + reserved
    }

    func connectionCount(inNetgroup group: String, excluding peer: PeerKey?) -> Int {
        sessions.values.lazy.filter { session in
            session.peerKey != peer
                && (self.links[session.link].map {
                    $0.isDirect && self.linkNetgroup($0) == group
                } ?? false)
        }.count
    }

    /// Admits an inbound link to the handshake, or closes it. Capacity is
    /// taken here, before the connection is read.
    mutating func registerInboundLink(_ id: LinkID) -> Bool {
        guard let link = links[id] else { return false }
        guard isRunning,
              connectionCapacityUsed < config.maxInboundConnections,
              !link.isDirect
                || directConnectionCount(inNetgroup: linkNetgroup(link))
                    < config.maxConnectionsPerNetgroup else {
            removeLink(id, notifyTransport: true)
            return false
        }
        pendingSessions[id] = PendingSession(link: id, direction: .responder)
        timers.set(.pendingSession(id), at: now.uptime + Self.pendingSessionTimeout)
        return true
    }

    // MARK: - Handshake

    /// Starts the initiator handshake on `id`. The outcome reaches `op`
    /// through `authenticationFinished`.
    mutating func authenticateInitiator(
        _ id: LinkID,
        expected: PeerKey,
        routeBinding: Data,
        op: OpID?
    ) {
        guard let metadata = localMetadata(for: id).encode(),
              let signed = try? SignedSessionHelloInitiator.sign(
                SessionHelloInitiator(
                    routeBinding: routeBinding,
                    initiator: localKey,
                    responder: expected,
                    nonce: random.bytes32(),
                    metadata: metadata),
                with: scheme) else {
            removeLink(id, notifyTransport: true)
            if let op { authResults.append((op, false)) }
            return
        }
        pendingSessions[id] = PendingSession(
            link: id,
            direction: .initiator(expected: expected, routeBinding: routeBinding),
            helloInitiator: signed,
            op: op)
        guard case .sent = sendSessionRecord(.helloInitiator(signed), on: id) else {
            failPendingSession(id)
            return
        }
        timers.set(.pendingSession(id), at: now.uptime + Self.pendingSessionTimeout)
    }

    mutating func failPendingSession(_ id: LinkID) {
        guard let pending = pendingSessions.removeValue(forKey: id) else { return }
        timers.cancel(.pendingSession(id))
        removeLink(id, notifyTransport: true)
        if let peer = pending.remoteKey { updateResponderWaiter(for: peer) }
        if let op = pending.op { authResults.append((op, false)) }
    }

    mutating func handleSessionRecord(_ bytes: Data, on id: LinkID) {
        let record: SessionWireRecord
        do {
            // Inbound: accept up to what THIS node advertised it accepts.
            record = try SessionWireRecord.deserialize(bytes, maxPayload: config.protocolMaxFrameSize)
        } catch {
            rejectRecord(on: id)
            return
        }

        if let key = sessionKeyByLink[id], let session = sessions[key], session.link == id {
            guard case .data(let dataRecord) = record else {
                rejectSession(session.ref, attributedTo: nil)
                return
            }
            handleAuthenticatedData(dataRecord, session: session)
            return
        }
        guard pendingSessions[id] != nil else {
            removeLink(id, notifyTransport: true)
            return
        }
        handlePendingRecord(record, on: id)
    }

    private mutating func handlePendingRecord(_ record: SessionWireRecord, on id: LinkID) {
        guard var pending = pendingSessions[id] else { return }

        switch record {
        case .helloInitiator(let signed):
            guard case .responder = pending.direction,
                  pending.helloInitiator == nil,
                  signed.isValid(using: scheme),
                  acceptsInboundHello(signed.hello, on: id),
                  peerMeetsDifficulty(signed.hello.initiator),
                  let remoteMetadata = try? PeerMetadata.decodeCanonical(signed.hello.metadata),
                  let localMetadata = localMetadata(for: id).encode() else {
                rejectRecord(on: id)
                return
            }
            // Negotiated: cap what we send this peer at what it advertised it accepts.
            links[id]?.peerMaxFrameSize = remoteMetadata.maxFrameSize

            let helloResponder = SessionHelloResponder(
                routeBinding: signed.hello.routeBinding,
                responder: localKey,
                initiator: signed.hello.initiator,
                initiatorNonce: signed.hello.nonce,
                responderNonce: random.bytes32(),
                metadata: localMetadata)
            guard let signedResponder = try? SignedSessionHelloResponder.sign(
                    helloResponder,
                    with: scheme),
                  let sessionID = try? SessionID(initiator: signed, responder: signedResponder) else {
                rejectRecord(on: id)
                return
            }

            pending.helloInitiator = signed
            pending.helloResponder = signedResponder
            pending.sessionID = sessionID
            pending.remoteKey = signed.hello.initiator
            pending.remoteMetadata = remoteMetadata
            pendingSessions[id] = pending
            guard case .sent = sendSessionRecord(.helloResponder(signedResponder), on: id) else {
                failPendingSession(id)
                return
            }

        case .helloResponder(let signed):
            guard case .initiator(let expected, let routeBinding) = pending.direction,
                  let helloInitiator = pending.helloInitiator,
                  pending.helloResponder == nil,
                  signed.isValid(using: scheme),
                  signed.hello.routeBinding == routeBinding,
                  signed.hello.responder == expected,
                  signed.hello.initiator == localKey,
                  signed.hello.initiatorNonce == helloInitiator.hello.nonce,
                  peerMeetsDifficulty(expected),
                  let remoteMetadata = try? PeerMetadata.decodeCanonical(signed.hello.metadata),
                  let sessionID = try? SessionID(initiator: helloInitiator, responder: signed),
                  let finish = try? SessionFinish.sign(
                    sessionID: sessionID,
                    sender: localKey,
                    receiver: expected,
                    with: scheme) else {
                rejectRecord(on: id)
                return
            }
            // Negotiated: cap what we send this peer at what it advertised it accepts.
            links[id]?.peerMaxFrameSize = remoteMetadata.maxFrameSize

            pending.helloResponder = signed
            pending.sessionID = sessionID
            pending.remoteKey = expected
            pending.remoteMetadata = remoteMetadata
            pendingSessions[id] = pending
            guard case .sent = sendSessionRecord(.finish(finish), on: id) else {
                failPendingSession(id)
                return
            }
            promotePendingSession(id)

        case .finish(let finish):
            guard case .responder = pending.direction,
                  let sessionID = pending.sessionID,
                  let remoteKey = pending.remoteKey,
                  finish.sessionID == sessionID,
                  finish.sender == remoteKey,
                  finish.receiver == localKey,
                  finish.isValid(using: scheme) else {
                rejectRecord(on: id)
                return
            }
            promotePendingSession(id)

        case .data:
            rejectRecord(on: id)
        }
    }

    func acceptsInboundHello(_ hello: SessionHelloInitiator, on id: LinkID) -> Bool {
        guard hello.responder == localKey, hello.initiator != localKey,
              let link = links[id] else { return false }
        switch link.transport {
        case .direct:
            guard hello.routeBinding == Self.directRouteBinding else { return false }
            return config.allowsEndpoint(hello.initiator)
                || config.isConfiguredCarrier(hello.initiator)
        case .relayed(let routeID, let carrier):
            guard hello.routeBinding == routeID,
                  let installed = installedRoutes[routeID],
                  installed.carrier == carrier,
                  installed.remote == hello.initiator else { return false }
            return config.allowsEndpoint(hello.initiator)
        }
    }

    private func peerMeetsDifficulty(_ key: PeerKey) -> Bool {
        config.minPeerKeyBits == 0
            || KeyDifficulty.trailingZeroBits(of: key.hex) >= config.minPeerKeyBits
    }

    private func localMetadata(for id: LinkID) -> PeerMetadata {
        PeerMetadata(
            listenAddresses: advertisedListenAddresses(observedLocalHost: links[id]?.localHost),
            maxFrameSize: config.protocolMaxFrameSize)
    }

    func advertisedListenAddresses(observedLocalHost: String?) -> [ListenAddress] {
        var addresses: [ListenAddress] = []
        if let external = config.externalAddress {
            addresses.append(ListenAddress(host: external.host, port: external.port))
        } else {
            if let publicAddress, config.listenPort != 0 {
                addresses.append(ListenAddress(host: publicAddress.host, port: config.listenPort))
            }
            if config.listenPort != 0,
               let localHost = observedLocalHost,
               localHost != "0.0.0.0", localHost != "::" {
                addresses.append(ListenAddress(host: localHost, port: config.listenPort))
            }
        }
        return addresses
    }

    // MARK: - Promotion

    private mutating func promotePendingSession(_ id: LinkID) {
        guard let pending = pendingSessions[id] else { return }
        guard isRunning,
              var link = links[id],
              let peerKey = pending.remoteKey,
              let metadata = pending.remoteMetadata,
              let sessionID = pending.sessionID,
              pending.helloInitiator != nil else {
            failPendingSession(id)
            return
        }
        pendingSessions.removeValue(forKey: id)
        timers.cancel(.pendingSession(id))

        // Role is local policy: configured carrier identities stay carrier-only.
        let role: AuthenticatedPeerRole = config.isConfiguredCarrier(peerKey) ? .carrier : .endpoint
        let existing = sessions[peerKey]

        // Simultaneous sessions converge on the smaller session ID.
        if let existing, isLive(existing.link),
           existing.sessionID == min(existing.sessionID, sessionID) {
            resolveResponderWaiter(for: peerKey, result: true)
            removeLink(id, notifyTransport: true)
            if let op = pending.op { authResults.append((op, true)) }
            return
        }

        let isInbound: Bool
        if case .responder = pending.direction { isInbound = true } else { isInbound = false }
        guard canPromote(link, peerKey: peerKey, isInbound: isInbound) else {
            removeLink(id, notifyTransport: true)
            updateResponderWaiter(for: peerKey)
            if let op = pending.op { authResults.append((op, false)) }
            return
        }

        if let existing, existing.role == .endpoint {
            router.removePeer(peerKey.peerID)
            cleanupPendingForPeer(peerKey.peerID)
        }
        var session = Session(
            link: id,
            peerKey: peerKey,
            role: role,
            sessionID: sessionID,
            metadata: metadata)
        sessions[peerKey] = session
        sessionKeyByLink[id] = peerKey
        if let existing {
            // The new session is selected before the old one's routes and
            // link go, so the old one ends without a disconnect (its peer is
            // still connected) and the route the new one rides on is kept.
            removeRoutes(involving: peerKey, preserving: id)
            if let op = existing.op { authResults.append((op, true)) }
            removeLink(existing.link, notifyTransport: true)
        }

        resolveResponderWaiter(for: peerKey, result: true)
        if !reconnectSuppressed.contains(peerKey.peerID) {
            reconnectAttempts.removeValue(forKey: peerKey.peerID)
            cancelScheduledReconnect(peerKey.peerID)
        }
        if role == .endpoint {
            let route: PeerEndpoint?
            if let endpoint = firstAdvertisedListenEndpoint(
                key: peerKey,
                addresses: metadata.listenAddresses,
                from: peerKey.peerID) {
                route = endpoint
            } else if case .initiator = pending.direction,
                      !link.endpoint.host.isEmpty,
                      link.endpoint.host != "unknown",
                      link.endpoint.port != 0 {
                route = PeerEndpoint(
                    publicKey: peerKey.hex,
                    host: link.endpoint.host,
                    port: link.endpoint.port)
            } else {
                route = nil
            }
            if let route {
                link.endpoint = route
                links[id]?.endpoint = route
                if config.mode.usesOverlayServices {
                    router.addPeer(peerKey.peerID, endpoint: route)
                }
            }
        }
        if health[peerKey.peerID]?.sessionID != sessionID {
            health[peerKey.peerID] = PeerHealth(sessionID: sessionID, lastActivity: now.uptime)
        }

        // The application sees the session before any of its records: the
        // link stays blocked until `delivered`.
        session.didNotifyConnect = true
        session.op = pending.op
        sessions[peerKey] = session
        let token = blockForDelivery(id, connected: peerKey)
        emit(.peerConnected(token, authenticatedPeer(session)))
    }

    /// The application has seen the session on `link`.
    mutating func connectDelivered(_ key: PeerKey, link: LinkID) {
        guard var session = sessions[key], session.link == link, let op = session.op else { return }
        session.op = nil
        sessions[key] = session
        authResults.append((op, true))
    }

    func canPromote(_ link: Link, peerKey: PeerKey, isInbound: Bool) -> Bool {
        let limit = isInbound ? config.maxInboundConnections : config.maxConnections
        if sessions[peerKey] == nil, sessions.count >= limit {
            return false
        }
        return !link.isDirect
            || connectionCount(inNetgroup: linkNetgroup(link), excluding: peerKey)
                < config.maxConnectionsPerNetgroup
    }

    private func firstAdvertisedListenEndpoint(
        key: PeerKey,
        addresses: [ListenAddress],
        from peer: PeerID
    ) -> PeerEndpoint? {
        for address in addresses {
            let endpoint = PeerEndpoint(publicKey: key.hex, host: address.host, port: address.port)
            if isAcceptableDiscoveredEndpoint(endpoint, provenance: .selfAdvertisement, from: peer) {
                return endpoint
            }
        }
        return nil
    }

    // MARK: - Ending sessions

    private mutating func rejectRecord(on id: LinkID) {
        if let key = sessionKeyByLink[id], let session = sessions[key], session.link == id {
            rejectSession(session.ref, attributedTo: nil)
            return
        }
        if pendingSessions[id] != nil {
            failPendingSession(id)
        } else {
            removeLink(id, notifyTransport: true)
        }
    }

    mutating func rejectSession(_ ref: SessionRef, attributedTo peer: PeerKey?) {
        if let peer { ledger.recordProtocolViolation(peer: peer.peerID) }
        teardownSession(ref, reconnect: false)
        removeLink(ref.link, notifyTransport: true)
    }

    /// Removes the session from every table. The caller closes its link.
    mutating func teardownSession(_ ref: SessionRef, reconnect: Bool) {
        guard let session = sessions[ref.key], session.link == ref.link else { return }
        let key = ref.key
        sessions.removeValue(forKey: key)
        sessionKeyByLink.removeValue(forKey: ref.link)
        if session.role == .endpoint {
            router.removePeer(key.peerID)
            cleanupPendingForPeer(key.peerID)
        }
        removeRoutes(involving: key)
        if health[key.peerID]?.sessionID == session.sessionID {
            health.removeValue(forKey: key.peerID)
        }
        if let op = session.op { authResults.append((op, false)) }
        if session.didNotifyConnect { emit(.peerDisconnected(key.peerID)) }

        guard reconnect, isRunning,
              !configuredEndpoints(for: key, role: session.role).isEmpty else { return }
        scheduleReconnect(peer: key.peerID, role: session.role)
    }

    func configuredEndpoints(for key: PeerKey, role: AuthenticatedPeerRole) -> [PeerEndpoint] {
        let endpoints = role == .carrier ? config.carriers : config.bootstrapPeers
        return endpoints.filter { (try? PeerKey($0.publicKey)) == key }
    }

    func configuredPeerKeys(role: AuthenticatedPeerRole) -> [PeerKey] {
        let endpoints = role == .carrier ? config.carriers : config.bootstrapPeers
        var seen: Set<PeerKey> = []
        return endpoints.compactMap { endpoint in
            guard let key = try? PeerKey(endpoint.publicKey), seen.insert(key).inserted else {
                return nil
            }
            return key
        }
    }

    mutating func disconnect(_ peer: PeerID) {
        guard let key = try? PeerKey(peer.publicKey) else { return }
        reconnectSuppressed.insert(key.peerID)
        cancelScheduledReconnect(key.peerID)
        reconnectAttempts.removeValue(forKey: key.peerID)
        outgoingDials[key.peerID]?.cancelled = true
        let pendingIDs = pendingSessions.compactMap { id, pending -> LinkID? in
            switch pending.direction {
            case .initiator(let expected, _):
                return expected == key ? id : nil
            case .responder:
                return pending.remoteKey == key ? id : nil
            }
        }
        for id in pendingIDs.sorted() { failPendingSession(id) }
        resolveResponderWaiter(for: key, result: false)
        removeRoutes(involving: key)
        if let session = sessions[key] {
            teardownSession(session.ref, reconnect: false)
            removeLink(session.link, notifyTransport: true)
        }
    }

    /// Close only the represented authenticated session. Configured peers
    /// reconnect automatically; unconfigured peers may reconnect themselves.
    /// A stale callback cannot close a replacement session for the same key.
    mutating func recycleSession(ifCurrent peer: AuthenticatedPeer) -> Bool {
        guard let session = sessions[peer.key],
              session.sessionID.bytes == peer.sessionID else { return false }
        let reconnect = !configuredEndpoints(for: peer.key, role: session.role).isEmpty
        teardownSession(session.ref, reconnect: reconnect)
        removeLink(session.link, notifyTransport: true)
        return true
    }

    /// Permanently close only the represented authenticated session. A stale
    /// callback cannot suppress or close its replacement for the same key.
    mutating func disconnectSession(ifCurrent peer: AuthenticatedPeer) -> Bool {
        guard let session = sessions[peer.key],
              session.sessionID.bytes == peer.sessionID else { return false }
        reconnectSuppressed.insert(peer.id)
        cancelScheduledReconnect(peer.id)
        reconnectAttempts.removeValue(forKey: peer.id)
        teardownSession(session.ref, reconnect: false)
        removeLink(session.link, notifyTransport: true)
        return true
    }

    // MARK: - Signed sending

    @discardableResult
    mutating func fireToPeer(_ peer: PeerID, _ message: Message) -> SendMessageResult {
        guard let key = try? PeerKey(peer.publicKey) else { return .notConnected }
        if let session = endpointSession(for: key) {
            return enqueue(message, on: session.ref)
        } else if message.isKeepalive, let session = carrierSession(for: key) {
            return enqueue(message, on: session.ref)
        }
        return .notConnected
    }

    mutating func enqueueEndpoint(_ message: Message, to peer: PeerID) -> SendMessageResult {
        guard let session = endpointSession(for: peer) else { return .notConnected }
        return enqueue(message, on: session.ref)
    }

    /// Signs and sends `message` on exactly the session `ref` names.
    @discardableResult
    mutating func enqueue(_ message: Message, on ref: SessionRef) -> SendMessageResult {
        guard isCurrent(ref) else { return .notConnected }
        let payload = message.serialize(maxFrameSize: effectiveOutboundFrameSize(for: ref.link))
        guard !payload.isEmpty else { return .locallyRejected }
        return enqueuePayload(payload, on: ref)
    }

    mutating func enqueuePayload(_ payload: Data, on ref: SessionRef) -> SendMessageResult {
        guard isCurrent(ref), let session = sessions[ref.key] else { return .notConnected }
        switch sessionRecordReadiness(on: ref.link) {
        case .sent:
            break
        case .backpressured:
            return .backpressured
        case .notConnected, .locallyRejected:
            return .notConnected
        }
        var sequenceState = session.sequenceState
        guard let sequence = sequenceState.takeNextOutgoing() else { return .locallyRejected }
        guard let record = try? SessionDataRecord.sign(
            sessionID: session.sessionID,
            sender: localKey,
            receiver: session.peerKey,
            sequence: sequence,
            payload: payload,
            with: scheme) else { return .locallyRejected }
        switch sendSessionRecord(.data(record), on: ref.link) {
        case .sent:
            // The send may have ended the session it travelled on.
            guard sessions[ref.key]?.link == ref.link else { return .notConnected }
            sessions[ref.key]?.sequenceState = sequenceState
        case .backpressured:
            return .backpressured
        case .locallyRejected:
            return .locallyRejected
        case .notConnected:
            return .notConnected
        }
        ledger.recordSent(peer: session.peerKey.peerID, bytes: payload.count)
        return .enqueued(
            endpoint: session.peerKey.peerID,
            route: links[ref.link]?.route ?? .direct)
    }

    mutating func sendSessionRecord(_ record: SessionWireRecord, on id: LinkID) -> LinkSendResult {
        let payload = record.serialize(maxPayload: effectiveOutboundFrameSize(for: id))
        guard !payload.isEmpty else { return .locallyRejected }
        guard let link = links[id] else { return .notConnected }
        switch link.transport {
        case .direct:
            return sendSerializedRecord(payload, on: id)
        case .relayed(let routeID, let carrier):
            guard installedRoutes[routeID]?.carrier == carrier else { return .notConnected }
            return sendRelayControlResult(
                .relayPacket(routeID: routeID, opaqueEndpointRecord: payload),
                to: carrier)
        }
    }

    /// `.sent` here means ready to send.
    func sessionRecordReadiness(on id: LinkID) -> LinkSendResult {
        guard let target = readinessLink(for: id), let link = links[target] else {
            return .notConnected
        }
        return link.writable ? .sent : .backpressured
    }

    func directRelayCarrierSession(for carrier: PeerKey) -> Session? {
        guard let session = sessions[carrier],
              links[session.link]?.isDirect == true else { return nil }
        return session
    }

    // MARK: - Signed receiving

    private mutating func handleAuthenticatedData(_ record: SessionDataRecord, session: Session) {
        let ref = session.ref
        guard isCurrent(ref) else { return }
        let direct = links[ref.link]?.isDirect ?? false
        guard record.sessionID == session.sessionID,
              session.sequenceState.canAcceptIncoming(record.sequence),
              record.isValid(sender: session.peerKey, receiver: localKey, using: scheme) else {
            rejectSession(ref, attributedTo: nil)
            return
        }
        guard sessions[ref.key]?.sequenceState.acceptIncoming(record.sequence) == true else {
            rejectSession(ref, attributedTo: Self.attributedPeer(
                session.peerKey, direct: direct, evidence: .signedTransport))
            return
        }
        ledger.recordReceived(peer: session.peerKey.peerID, bytes: record.payload.count)

        guard let message = Message.deserialize(
            record.payload, maxDataPayload: config.protocolMaxFrameSize) else {
            // A message a later version added is ignored, so a peer may be
            // sent one before this version knows it. A known message that
            // does not decode is a violation.
            guard !Message.hasUnknownTag(record.payload) else { return }
            rejectSession(ref, attributedTo: Self.attributedPeer(
                session.peerKey, direct: direct, evidence: .signedPayload))
            return
        }

        if message.isRelayControl {
            guard config.mode.usesOverlayServices else { return }
            guard sessionMayCarryRelayControl(message, session: session) else {
                rejectSession(ref, attributedTo: session.peerKey)
                return
            }
            handleRelayControl(message, from: session.peerKey, link: ref.link)
            return
        }

        if session.role == .carrier {
            switch message {
            case .ping, .pong:
                break
            default:
                rejectSession(ref, attributedTo: session.peerKey)
                return
            }
        }
        handleMessage(message, from: ref)
    }

    // MARK: - Keepalive

    mutating func runHealthCycle() {
        let config = config.healthConfig
        timers.set(.health, at: now.uptime + config.keepaliveInterval)
        var stale: [(PeerID, SessionID)] = []
        var pings: [(PeerID, SessionID, UInt64)] = []

        for peer in health.keys.sorted(by: { $0.publicKey < $1.publicKey }) {
            guard var entry = health[peer] else { continue }
            let sinceActivity = now.uptime - entry.lastActivity
            if sinceActivity >= config.staleTimeout {
                stale.append((peer, entry.sessionID))
                continue
            }
            guard sinceActivity >= config.keepaliveInterval else { continue }
            if entry.pendingPingNonce != nil {
                entry.missedPongs += 1
                if entry.missedPongs >= config.maxMissedPongs {
                    stale.append((peer, entry.sessionID))
                    continue
                }
            }
            let nonce = random.next()
            entry.pendingPingNonce = nonce
            health[peer] = entry
            pings.append((peer, entry.sessionID, nonce))
        }
        for (peer, _) in stale { health.removeValue(forKey: peer) }

        for (peer, sessionID, nonce) in pings {
            guard let key = try? PeerKey(peer.publicKey),
                  sessions[key]?.sessionID == sessionID else { continue }
            fireToPeer(peer, .ping(nonce: nonce))
        }
        for (peer, sessionID) in stale {
            guard let key = try? PeerKey(peer.publicKey),
                  let session = sessions[key],
                  session.sessionID == sessionID else { continue }
            teardownSession(session.ref, reconnect: true)
            removeLink(session.link, notifyTransport: true)
        }
    }

    mutating func recordHealthActivity(_ session: Session, pong nonce: UInt64? = nil) {
        let peer = session.peerKey.peerID
        guard var entry = health[peer], entry.sessionID == session.sessionID else { return }
        if let nonce, entry.pendingPingNonce != nonce { return }
        entry.lastActivity = now.uptime
        entry.pendingPingNonce = nil
        entry.missedPongs = 0
        health[peer] = entry
    }
}

extension Message {
    var isRelayControl: Bool {
        switch self {
        case .relayOpen, .relayOffer, .relayAccept, .relayReady, .relayPacket, .relayClose:
            return true
        default:
            return false
        }
    }
}
