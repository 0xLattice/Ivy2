import Foundation
import Tally

/// A route this node carries between two of its direct peers.
struct RelayRoute: Sendable {
    let source: PeerKey
    let target: PeerKey
    var ready: Bool
    var lastActivity: Duration
}

/// A route a carrier holds for this node, to one remote endpoint.
struct InstalledRoute: Sendable {
    let carrier: PeerKey
    let remote: PeerKey
    /// The relayed link riding the route, once its handshake has begun.
    var link: LinkID?
}

struct PendingRelayOpen: Sendable {
    let carrier: PeerKey
    let target: PeerKey
    let op: OpID?
}

extension IvyCore {
    // MARK: - Route cleanup

    mutating func removeRoutes(involving key: PeerKey, preserving link: LinkID? = nil) {
        let preservedRouteID: Data?
        if let link, case .relayed(let routeID, _) = links[link]?.transport {
            preservedRouteID = routeID
        } else {
            preservedRouteID = nil
        }
        let order: (Data, Data) -> Bool = { $0.lexicographicallyPrecedes($1) }

        let serviceRouteIDs = relayRoutes.compactMap { routeID, route in
            routeID != preservedRouteID && (route.source == key || route.target == key)
                ? routeID : nil
        }
        for routeID in serviceRouteIDs.sorted(by: order) {
            closeRelayRoute(routeID, excluding: key)
        }

        let installedRouteIDs = installedRoutes.compactMap { routeID, route in
            routeID != preservedRouteID && (route.carrier == key || route.remote == key)
                ? routeID : nil
        }
        for routeID in installedRouteIDs.sorted(by: order) {
            guard let route = installedRoutes[routeID] else { continue }
            closeInstalledRoute(routeID, notifyCarrier: route.carrier != key)
        }

        let requestIDs = pendingRelayOpens.compactMap { requestID, request in
            requestID != preservedRouteID && (request.carrier == key || request.target == key)
                ? requestID : nil
        }
        for requestID in requestIDs.sorted(by: order) {
            timeoutRelayOpen(requestID)
        }
    }

    mutating func closeRelayRoute(_ routeID: Data, excluding excluded: PeerKey? = nil) {
        // Told while the route still exists: only a route's participants
        // may be sent its close.
        guard let route = relayRoutes[routeID] else { return }
        for participant in [route.source, route.target] where participant != excluded {
            _ = sendRelayControl(.relayClose(routeID: routeID), to: participant)
        }
        relayRoutes.removeValue(forKey: routeID)
        timers.cancel(.relayRoute(routeID))
    }

    mutating func closeInstalledRoute(_ routeID: Data, notifyCarrier: Bool) {
        guard let route = installedRoutes[routeID] else { return }
        if notifyCarrier {
            _ = sendRelayControl(.relayClose(routeID: routeID), to: route.carrier)
        }
        installedRoutes.removeValue(forKey: routeID)
        timers.cancel(.installedRoute(routeID))
        if let link = route.link { removeLink(link, notifyTransport: true) }
    }

    private mutating func removePendingRelayOpen(_ routeID: Data) -> PendingRelayOpen? {
        timers.cancel(.relayOpen(routeID))
        return pendingRelayOpens.removeValue(forKey: routeID)
    }

    // MARK: - Sending relay control

    mutating func sendRelayControl(_ message: Message, to key: PeerKey) -> Bool {
        sendRelayControlResult(message, to: key) == .sent
    }

    mutating func sendRelayControlResult(_ message: Message, to key: PeerKey) -> LinkSendResult {
        let session: Session?
        if let carrier = carrierSession(for: key) {
            session = carrier
        } else if let endpoint = endpointSession(for: key),
                  links[endpoint.link]?.isDirect == true,
                  endpointMayReceiveRelayControl(message, peer: key) {
            session = endpoint
        } else {
            session = nil
        }
        guard let session else { return .notConnected }
        switch enqueue(message, on: session.ref) {
        case .enqueued:
            return .sent
        case .backpressured:
            return .backpressured
        case .locallyRejected:
            return .locallyRejected
        case .notConnected:
            return .notConnected
        }
    }

    private mutating func sendRelayReply(_ message: Message, to key: PeerKey) -> Bool {
        guard let session = sessions[key], links[session.link]?.isDirect == true else { return false }
        if case .enqueued = enqueue(message, on: session.ref) { return true }
        return false
    }

    // MARK: - Who may send what

    func sessionMayCarryRelayControl(_ message: Message, session: Session) -> Bool {
        guard links[session.link]?.isDirect == true else { return false }
        switch message {
        case .relayOpen:
            return config.relayEnabled
        case .relayOffer:
            // Inbound route offers do not grant endpoint authority. The
            // relayed handshake still authenticates both endpoint keys.
            return true
        case .relayAccept(let routeID, _):
            if let route = relayRoutes[routeID] { return route.target == session.peerKey }
            return config.relayEnabled && relayRouteIsUnknown(routeID)
        case .relayReady(let routeID, _):
            return pendingRelayOpens[routeID]?.carrier == session.peerKey
                || installedRoutes[routeID]?.carrier == session.peerKey
                || (config.isConfiguredCarrier(session.peerKey) && relayRouteIsUnknown(routeID))
        case .relayPacket(let routeID, _), .relayClose(let routeID):
            // Unknown and late frames are idempotent no-ops.
            return relayRouteIsUnknown(routeID)
                || relayParticipant(routeID, peer: session.peerKey)
        default:
            return false
        }
    }

    private func endpointMayReceiveRelayControl(_ message: Message, peer: PeerKey) -> Bool {
        switch message {
        case .relayOffer(let routeID, _):
            return config.relayEnabled && relayRoutes[routeID]?.target == peer
        case .relayReady(let routeID, _):
            return config.relayEnabled && relayRoutes[routeID]?.source == peer
        case .relayAccept(let routeID, _), .relayPacket(let routeID, _), .relayClose(let routeID):
            return relayParticipant(routeID, peer: peer)
        default:
            return false
        }
    }

    private func relayParticipant(_ routeID: Data, peer: PeerKey) -> Bool {
        if let route = relayRoutes[routeID] {
            return route.source == peer || route.target == peer
        }
        return installedRoutes[routeID]?.carrier == peer
            || pendingRelayOpens[routeID]?.carrier == peer
    }

    func relayRouteIsUnknown(_ routeID: Data) -> Bool {
        routeID != Self.directRouteBinding
            && relayRoutes[routeID] == nil
            && installedRoutes[routeID] == nil
            && pendingRelayOpens[routeID] == nil
    }

    // MARK: - Opening a route (as an endpoint)

    /// Asks `carrier` for a route to `target`. Nil when the request could
    /// not be made; otherwise `relayOpenFinished` reports how it ended.
    mutating func requestRelayRoute(target: PeerKey, via carrier: PeerKey, op: OpID?) -> Data? {
        guard isRunning,
              installedRoutes.count + pendingRelayOpens.count < Self.maxRelayRoutes,
              installedRoutes.values.lazy.filter({ $0.carrier == carrier }).count
                + pendingRelayOpens.values.lazy.filter({ $0.carrier == carrier }).count
                < Self.maxRelayRoutesPerPeer else { return nil }
        var routeID = random.bytes32()
        while !relayRouteIsUnknown(routeID) { routeID = random.bytes32() }

        pendingRelayOpens[routeID] = PendingRelayOpen(carrier: carrier, target: target, op: op)
        guard sendRelayControl(.relayOpen(routeID: routeID, targetKey: target), to: carrier) else {
            pendingRelayOpens.removeValue(forKey: routeID)
            return nil
        }
        timers.set(.relayOpen(routeID), at: now.uptime + config.relayTimeout)
        return routeID
    }

    mutating func timeoutRelayOpen(_ routeID: Data) {
        guard let pending = removePendingRelayOpen(routeID) else { return }
        _ = sendRelayControl(.relayClose(routeID: routeID), to: pending.carrier)
        if let op = pending.op {
            relayOpenFinished(op, routeID: routeID, carrier: pending.carrier, opened: false)
        }
    }

    mutating func openInstalledRouteLink(
        endpoint: PeerEndpoint,
        target: PeerKey,
        routeID: Data,
        carrier: PeerKey
    ) -> LinkID? {
        guard let route = installedRoutes[routeID],
              route.carrier == carrier,
              route.remote == target,
              route.link == nil,
              connectionCapacityUsed < config.maxConnections else { return nil }
        let link = makeLink(.relayed(routeID: routeID, carrier: carrier), endpoint: endpoint)
        installedRoutes[routeID]?.link = link
        return link
    }

    // MARK: - Handling relay control

    mutating func handleRelayControl(_ message: Message, from sender: PeerKey, link: LinkID) {
        switch message {
        case .relayOpen(let routeID, let target):
            guard routeID.count == 32, relayRouteIsUnknown(routeID) else {
                ledger.recordProtocolViolation(peer: sender.peerID)
                return
            }
            guard relayRoutes.count < Self.maxRelayRoutes,
                  relayRoutes.values.lazy.filter({ $0.source == sender }).count
                    < Self.maxRelayRoutesPerPeer,
                  config.relayEnabled,
                  sender != target,
                  let targetSession = endpointSession(for: target),
                  links[targetSession.link]?.isDirect == true else {
                _ = sendRelayReply(.relayReady(routeID: routeID, status: 1), to: sender)
                return
            }
            relayRoutes[routeID] = RelayRoute(
                source: sender, target: target, ready: false, lastActivity: now.uptime)
            timers.set(.relayRoute(routeID), at: now.uptime + config.relayTimeout)
            guard sendRelayControl(.relayOffer(routeID: routeID, sourceKey: sender), to: target) else {
                relayRoutes.removeValue(forKey: routeID)
                timers.cancel(.relayRoute(routeID))
                _ = sendRelayReply(.relayReady(routeID: routeID, status: 1), to: sender)
                return
            }

        case .relayOffer(let routeID, let source):
            guard routeID.count == 32,
                  source != localKey,
                  source != sender,
                  config.allowsEndpoint(source),
                  relayRouteIsUnknown(routeID),
                  installedRoutes.count + pendingRelayOpens.count < Self.maxRelayRoutes,
                  installedRoutes.values.lazy.filter({ $0.carrier == sender }).count
                    + pendingRelayOpens.values.lazy.filter({ $0.carrier == sender }).count
                    < Self.maxRelayRoutesPerPeer else {
                _ = sendRelayReply(.relayAccept(routeID: routeID, status: 1), to: sender)
                return
            }
            installedRoutes[routeID] = InstalledRoute(carrier: sender, remote: source)
            timers.set(.installedRoute(routeID), at: now.uptime + config.relayTimeout)
            guard sendRelayControl(.relayAccept(routeID: routeID, status: 0), to: sender) else {
                installedRoutes.removeValue(forKey: routeID)
                timers.cancel(.installedRoute(routeID))
                return
            }

        case .relayAccept(let routeID, let status):
            guard var route = relayRoutes[routeID] else { return }
            guard route.target == sender else {
                ledger.recordProtocolViolation(peer: sender.peerID)
                return
            }
            guard status == 0 else {
                relayRoutes.removeValue(forKey: routeID)
                timers.cancel(.relayRoute(routeID))
                _ = sendRelayReply(.relayReady(routeID: routeID, status: status), to: route.source)
                return
            }
            route.ready = true
            route.lastActivity = now.uptime
            relayRoutes[routeID] = route
            timers.set(.relayRoute(routeID), at: now.uptime + Self.relayIdleTimeout)
            guard sendRelayControl(.relayReady(routeID: routeID, status: 0), to: route.source) else {
                closeRelayRoute(routeID)
                return
            }

        case .relayReady(let routeID, let status):
            guard let pending = pendingRelayOpens[routeID] else { return }
            guard pending.carrier == sender else {
                ledger.recordProtocolViolation(peer: sender.peerID)
                return
            }
            _ = removePendingRelayOpen(routeID)
            var opened = false
            if status == 0 {
                if routeID.count == 32,
                   installedRoutes.count < Self.maxRelayRoutes,
                   installedRoutes.values.lazy.filter({ $0.carrier == sender }).count
                    < Self.maxRelayRoutesPerPeer,
                   relayRouteIsUnknown(routeID) {
                    installedRoutes[routeID] = InstalledRoute(carrier: sender, remote: pending.target)
                    timers.set(.installedRoute(routeID), at: now.uptime + config.relayTimeout)
                    opened = true
                } else {
                    _ = sendRelayControl(.relayClose(routeID: routeID), to: sender)
                }
            }
            if let op = pending.op {
                relayOpenFinished(op, routeID: routeID, carrier: sender, opened: opened)
            } else if opened {
                closeInstalledRoute(routeID, notifyCarrier: true)
            }

        case .relayClose(let routeID):
            if let route = relayRoutes[routeID] {
                guard route.source == sender || route.target == sender else { return }
                closeRelayRoute(routeID, excluding: sender)
                return
            }
            if let pending = pendingRelayOpens[routeID], pending.carrier == sender {
                _ = removePendingRelayOpen(routeID)
                if let op = pending.op {
                    relayOpenFinished(op, routeID: routeID, carrier: sender, opened: false)
                }
                return
            }
            guard installedRoutes[routeID]?.carrier == sender else { return }
            closeInstalledRoute(routeID, notifyCarrier: false)

        case .relayPacket(let routeID, let opaqueRecord):
            if var route = relayRoutes[routeID] {
                guard route.ready else { return }
                let destination: PeerKey
                if route.source == sender {
                    destination = route.target
                } else if route.target == sender {
                    destination = route.source
                } else {
                    ledger.recordProtocolViolation(peer: sender.peerID)
                    return
                }
                route.lastActivity = now.uptime
                relayRoutes[routeID] = route
                guard let destinationSession = endpointSession(for: destination),
                      links[destinationSession.link]?.isDirect == true else {
                    closeRelayRoute(routeID)
                    return
                }
                forwardRelayPacket(
                    opaqueRecord,
                    routeID: routeID,
                    destination: destinationSession.ref,
                    source: link)
                return
            }
            handleInstalledRoutePacket(opaqueRecord, routeID: routeID, from: sender)

        default:
            return
        }
    }

    private mutating func handleInstalledRoutePacket(
        _ opaqueRecord: Data,
        routeID: Data,
        from sender: PeerKey
    ) {
        guard let installed = installedRoutes[routeID], installed.carrier == sender else { return }
        if let link = installed.link {
            if !feedRecord(opaqueRecord, to: link) {
                closeInstalledRoute(routeID, notifyCarrier: true)
            }
            return
        }
        // The route's first record must be the offered peer's handshake.
        guard let firstRecord = try? SessionWireRecord.deserialize(
                opaqueRecord, maxPayload: config.protocolMaxFrameSize),
              case .helloInitiator(let hello) = firstRecord,
              hello.isValid(using: scheme),
              hello.hello.initiator == installed.remote,
              hello.hello.responder == localKey,
              hello.hello.routeBinding == routeID else {
            closeInstalledRoute(routeID, notifyCarrier: true)
            return
        }
        let link = makeLink(
            .relayed(routeID: routeID, carrier: sender),
            endpoint: PeerEndpoint(publicKey: installed.remote.hex, host: "relay", port: 0))
        guard registerInboundLink(link) else {
            closeInstalledRoute(routeID, notifyCarrier: true)
            return
        }
        installedRoutes[routeID]?.link = link
        if !feedRecord(opaqueRecord, to: link) {
            closeInstalledRoute(routeID, notifyCarrier: true)
        }
    }

    // MARK: - Forwarding (as a carrier)

    /// Forwards one record in arrival order. A destination that cannot take
    /// it holds the source's connection, and so the source, until it can or
    /// `requestTimeout` passes; the route is then retired.
    private mutating func forwardRelayPacket(
        _ opaqueRecord: Data,
        routeID: Data,
        destination: SessionRef,
        source: LinkID
    ) {
        let message = Message.relayPacket(routeID: routeID, opaqueEndpointRecord: opaqueRecord)
        switch enqueue(message, on: destination) {
        case .enqueued:
            return
        case .backpressured:
            guard links[source] != nil,
                  awaitWritable(destination.link, .relayForward(source)) else {
                closeRelayRoute(routeID)
                return
            }
            if case .relayForward = links[source]?.block {
                // A retry: the deadline set by the first attempt stands.
            } else {
                timers.set(.relayForward(source), at: now.uptime + config.requestTimeout)
            }
            links[source]?.block = .relayForward(routeID: routeID, record: opaqueRecord)
        case .notConnected, .locallyRejected:
            closeRelayRoute(routeID)
        }
    }

    mutating func relayForwardBecameWritable(_ source: LinkID, writable: Bool) {
        guard case .relayForward(let routeID, let record) = links[source]?.block else { return }
        guard writable else {
            closeRelayRoute(routeID)
            return endRelayForward(source)
        }
        guard let route = relayRoutes[routeID], let sender = sessionKeyByLink[source] else {
            return endRelayForward(source)
        }
        let destination = route.source == sender ? route.target : route.source
        guard let session = endpointSession(for: destination),
              links[session.link]?.isDirect == true else {
            return endRelayForward(source)
        }
        forwardRelayPacket(record, routeID: routeID, destination: session.ref, source: source)
        // Still waiting when the retry registered for writability again.
        let stillWaiting = writabilityWaiters.values.contains { $0.contains(.relayForward(source)) }
        if !stillWaiting { endRelayForward(source) }
    }

    mutating func relayForwardTimedOut(_ source: LinkID) {
        guard case .relayForward(let routeID, _) = links[source]?.block else { return }
        removeWritabilityWaiter(.relayForward(source))
        closeRelayRoute(routeID)
        endRelayForward(source)
    }

    private mutating func endRelayForward(_ source: LinkID) {
        guard case .relayForward = links[source]?.block else { return }
        timers.cancel(.relayForward(source))
        unblock(source)
    }

    // MARK: - Route deadlines

    mutating func relayRouteTimerFired(_ routeID: Data) {
        guard let route = relayRoutes[routeID] else { return }
        guard route.ready else { return closeRelayRoute(routeID) }
        let idle = now.uptime - route.lastActivity
        if idle >= Self.relayIdleTimeout {
            closeRelayRoute(routeID)
        } else {
            timers.set(.relayRoute(routeID), at: route.lastActivity + Self.relayIdleTimeout)
        }
    }

    /// An accepted route nobody opened a session on.
    mutating func expireIdleInstalledRoute(_ routeID: Data) {
        guard let route = installedRoutes[routeID], route.link == nil else { return }
        closeInstalledRoute(routeID, notifyCarrier: true)
    }
}
