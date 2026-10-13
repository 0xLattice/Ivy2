#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Tally

/// One byte path to a peer: a transport connection the shell owns, or a
/// route through a carrier's connection.
struct Link: Sendable {
    enum Transport: Sendable, Equatable {
        case direct(ConnectionID)
        case relayed(routeID: Data, carrier: PeerKey)
    }

    /// Why the link's next record is being held.
    enum Block: Sendable, Equatable {
        /// The application has not finished with the last delivery.
        case delivery(DeliveryToken)
        /// A relayed record is waiting for its destination to take it.
        case relayForward(routeID: Data, record: Data)
    }

    enum DecodeResult {
        case frame(Data)
        case needMore
        case stalled
        case malformed
    }

    let id: LinkID
    let transport: Transport
    var endpoint: PeerEndpoint
    var observedHost: String?
    var localHost: String?
    /// Max frame the peer advertised it will accept; outbound frames are
    /// capped here. The protocol default until the handshake lands.
    var peerMaxFrameSize: UInt32 = IvyConfig.defaultProtocolMaxFrameSize
    /// Inbound bytes this link may hold: two maximum local frames plus a header.
    let budgetLimit: Int

    // Inbound.
    private var carry = Data()
    private var carryOffset = 0
    private var header: [UInt8] = []
    private var expectedBodyLength: Int?
    private var body = Data()
    /// Bytes charged to the inbound budgets: the partial frame, queued
    /// records, and a record held by `block`.
    var charged = 0
    var heldBytes = 0
    var queue: [Data] = []
    var block: Block?
    var stalledOnBudget = false
    /// Whether the shell has been told to read this connection.
    var reading = false

    // Outbound.
    var unflushed = 0
    var writable = true

    init(
        id: LinkID,
        transport: Transport,
        endpoint: PeerEndpoint,
        observedHost: String?,
        localHost: String?,
        localMaxFrameSize: UInt32
    ) {
        self.id = id
        self.transport = transport
        self.endpoint = endpoint
        self.observedHost = observedHost
        self.localHost = localHost
        self.budgetLimit = Int(clamping: 2 * UInt64(localMaxFrameSize) + 4)
        if case .relayed = transport { writable = false }
    }

    var isDirect: Bool {
        if case .direct = transport { return true }
        return false
    }

    var route: AuthenticatedRoute {
        switch transport {
        case .direct:
            return .direct
        case .relayed(let routeID, let carrier):
            return .relayed(carrier: carrier, routeID: routeID)
        }
    }

    var undecodedByteCount: Int { carry.count - carryOffset }

    mutating func appendReceived(_ bytes: Data) {
        if carryOffset == carry.count {
            carry = bytes
            carryOffset = 0
        } else {
            if carryOffset > 64 * 1024 {
                carry = Data(carry[(carry.startIndex + carryOffset)...])
                carryOffset = 0
            }
            carry.append(bytes)
        }
    }

    private mutating func take(_ count: Int) -> Data {
        let start = carry.startIndex + carryOffset
        carryOffset += count
        return carry[start..<start + count]
    }

    private mutating func charge(_ count: Int, used: inout Int, limit: Int) -> Bool {
        guard count <= limit - used, count <= budgetLimit - charged else { return false }
        used += count
        charged += count
        return true
    }

    /// Decodes the next length-prefixed frame from the received bytes,
    /// charging each byte to the budgets as it joins the frame.
    mutating func decodeFrame(
        maxFrameSize: UInt32,
        used: inout Int,
        limit: Int
    ) -> DecodeResult {
        while undecodedByteCount > 0 {
            if expectedBodyLength == nil {
                if header.isEmpty {
                    guard charge(4, used: &used, limit: limit) else { return .stalled }
                }
                let count = min(4 - header.count, undecodedByteCount)
                header.append(contentsOf: take(count))
                guard header.count == 4 else { return .needMore }
                let length = UInt32(header[0]) << 24
                    | UInt32(header[1]) << 16
                    | UInt32(header[2]) << 8
                    | UInt32(header[3])
                guard length > 0, length <= maxFrameSize else { return .malformed }
                expectedBodyLength = Int(length)
                header.removeAll(keepingCapacity: true)
                // The header is consumed; only the body stays charged.
                used -= 4
                charged -= 4
                continue
            }
            guard let expectedBodyLength else { continue }
            let count = min(expectedBodyLength - body.count, undecodedByteCount)
            guard charge(count, used: &used, limit: limit) else { return .stalled }
            if body.isEmpty { body.reserveCapacity(expectedBodyLength) }
            body.append(take(count))
            guard body.count == expectedBodyLength else { return .needMore }
            let frame = body
            body = Data()
            self.expectedBodyLength = nil
            return .frame(frame)
        }
        return .needMore
    }
}

struct Delivery: Sendable {
    let link: LinkID
    /// Set when the delivery is the `peerConnected` for this peer's session.
    let connected: PeerKey?
}

enum WritabilityWaiter: Sendable, Equatable {
    case request(RequestID)
    case serving(InboundContentRequest)
    /// The source link of a relayed record waiting on its destination.
    case relayForward(LinkID)
}

enum LinkSendResult: Sendable, Equatable {
    case sent
    case backpressured
    case locallyRejected
    case notConnected
}

extension IvyCore {
    // MARK: - Opening

    mutating func connectionOpened(
        _ connection: ConnectionID,
        direction: ConnectionDirection,
        observedHost: String?,
        localHost: String?
    ) {
        guard linkByConnection[connection] == nil else { return }
        switch direction {
        case .inbound:
            let link = makeLink(
                .direct(connection),
                endpoint: PeerEndpoint(publicKey: "", host: "unknown", port: 0),
                observedHost: observedHost,
                localHost: localHost)
            guard registerInboundLink(link) else { return }
            syncReading(link)
        case .outbound(let dial):
            dialSucceeded(
                dial,
                connection: connection,
                observedHost: observedHost,
                localHost: localHost)
        }
    }

    @discardableResult
    mutating func makeLink(
        _ transport: Link.Transport,
        endpoint: PeerEndpoint,
        observedHost: String? = nil,
        localHost: String? = nil
    ) -> LinkID {
        let id = makeID()
        links[id] = Link(
            id: id,
            transport: transport,
            endpoint: endpoint,
            observedHost: observedHost,
            localHost: localHost,
            localMaxFrameSize: config.protocolMaxFrameSize)
        if case .direct(let connection) = transport { linkByConnection[connection] = id }
        return id
    }

    func isLive(_ link: LinkID) -> Bool {
        links[link] != nil
    }

    func linkNetgroup(_ link: Link) -> String {
        guard let host = link.observedHost, !host.isEmpty else {
            return "raw:connection:\(link.id)"
        }
        return NetGroup.group(host)
    }

    // MARK: - Closing

    /// Forgets a link and everything riding on it. `notifyTransport` is false
    /// when the shell reported the close.
    mutating func removeLink(_ id: LinkID, notifyTransport: Bool) {
        guard let link = links.removeValue(forKey: id) else { return }
        if case .direct(let connection) = link.transport {
            linkByConnection.removeValue(forKey: connection)
            if notifyTransport { emit(.close(connection)) }
        }
        budgetWaiters.remove(id)
        if case .delivery(let token) = link.block { deliveries.removeValue(forKey: token) }
        if case .relayForward = link.block { timers.cancel(.relayForward(id)) }
        removeWritabilityWaiter(.relayForward(id))
        releaseInbound(link.charged)
        resumeWritabilityWaiters(id, writable: false)

        if pendingSessions[id] != nil {
            failPendingSession(id)
        } else if let key = sessionKeyByLink[id], let session = sessions[key], session.link == id {
            teardownSession(session.ref, reconnect: true)
        }
        sessionKeyByLink.removeValue(forKey: id)
        if case .relayed(let routeID, _) = link.transport, installedRoutes[routeID]?.link == id {
            closeInstalledRoute(routeID, notifyCarrier: true)
        }
    }

    // MARK: - Inbound bytes

    mutating func received(_ bytes: Data, on connection: ConnectionID) {
        guard let id = linkByConnection[connection], !bytes.isEmpty else { return }
        links[id]?.appendReceived(bytes)
        pump(id)
    }

    /// Hands a carrier-delivered record to a relayed link. False when the
    /// link cannot take it, which ends the link.
    mutating func feedRecord(_ record: Data, to id: LinkID) -> Bool {
        guard var link = links[id] else { return false }
        guard !record.isEmpty,
              record.count <= Int(clamping: config.protocolMaxFrameSize),
              link.queue.count < Self.maxInboundBufferedRecords,
              record.count <= config.maxInboundBufferedBytes - inboundBytesUsed,
              record.count <= link.budgetLimit - link.charged else {
            removeLink(id, notifyTransport: true)
            return false
        }
        inboundBytesUsed += record.count
        link.charged += record.count
        link.queue.append(record)
        links[id] = link
        pump(id)
        return true
    }

    /// Handles the link's records in order until one blocks it, the bytes
    /// run out, or a budget is exhausted.
    mutating func pump(_ id: LinkID) {
        while true {
            guard var link = links[id], link.block == nil else { break }
            if !link.queue.isEmpty {
                let frame = link.queue.removeFirst()
                links[id] = link
                handleSessionRecord(frame, on: id)
                if links[id]?.block != nil {
                    links[id]?.heldBytes += frame.count
                } else if links[id] != nil {
                    links[id]?.charged -= frame.count
                    releaseInbound(frame.count)
                }
                continue
            }
            guard link.isDirect else { break }
            // Out of the table while it decodes, so the partial frame grows in place.
            links[id] = nil
            let result = link.decodeFrame(
                maxFrameSize: config.protocolMaxFrameSize,
                used: &inboundBytesUsed,
                limit: config.maxInboundBufferedBytes)
            switch result {
            case .frame(let frame):
                link.queue.append(frame)
                links[id] = link
            case .needMore:
                links[id] = link
                syncReading(id)
                return
            case .stalled:
                link.stalledOnBudget = true
                links[id] = link
                budgetWaiters.insert(id)
                syncReading(id)
                return
            case .malformed:
                links[id] = link
                removeLink(id, notifyTransport: true)
                return
            }
        }
        syncReading(id)
    }

    /// Returns inbound bytes to the node-wide budget and lets the links
    /// that stalled on it decode again.
    mutating func releaseInbound(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        inboundBytesUsed -= byteCount
        guard !budgetWaiters.isEmpty else { return }
        for id in budgetWaiters.sorted() {
            links[id]?.stalledOnBudget = false
            pumpQueue.append(id)
        }
        budgetWaiters.removeAll()
    }

    mutating func drainPumps() {
        while !pumpQueue.isEmpty {
            let id = pumpQueue.removeFirst()
            pump(id)
        }
    }

    /// A connection is read only while its next record could be handled:
    /// a blocked link, or one out of budget, holds its peer back.
    mutating func syncReading(_ id: LinkID) {
        guard let link = links[id], case .direct(let connection) = link.transport else { return }
        let wanted = link.block == nil && !link.stalledOnBudget
        guard wanted != link.reading else { return }
        links[id]?.reading = wanted
        emit(wanted ? .resumeReading(connection) : .pauseReading(connection))
    }

    // MARK: - Deliveries

    /// Holds the link's next record until the application finishes with this one.
    mutating func blockForDelivery(_ id: LinkID, connected: PeerKey? = nil) -> DeliveryToken {
        let token = DeliveryToken(makeID())
        deliveries[token] = Delivery(link: id, connected: connected)
        links[id]?.block = .delivery(token)
        return token
    }

    mutating func delivered(_ token: DeliveryToken) {
        guard let delivery = deliveries.removeValue(forKey: token),
              links[delivery.link]?.block == .delivery(token) else { return }
        unblock(delivery.link)
        if let key = delivery.connected { connectDelivered(key, link: delivery.link) }
    }

    mutating func unblock(_ id: LinkID) {
        guard var link = links[id] else { return }
        let held = link.heldBytes
        link.block = nil
        link.heldBytes = 0
        link.charged -= held
        links[id] = link
        releaseInbound(held)
        pumpQueue.append(id)
    }

    // MARK: - Outbound bytes

    /// Writes one framed record to a direct link.
    mutating func sendSerializedRecord(_ payload: Data, on id: LinkID) -> LinkSendResult {
        guard let link = links[id], case .direct(let connection) = link.transport else {
            return .notConnected
        }
        guard !payload.isEmpty, payload.count <= Int(clamping: link.peerMaxFrameSize) else {
            return .locallyRejected
        }
        guard link.writable else { return .backpressured }
        var frame = Data(capacity: 4 + payload.count)
        frame.appendUInt32(UInt32(payload.count))
        frame.append(payload)
        let unflushed = link.unflushed + frame.count
        links[id]?.unflushed = unflushed
        if unflushed > Self.writeHighWaterMark { links[id]?.writable = false }
        emit(.write(connection, frame))
        return .sent
    }

    mutating func transportBecameWritable(_ connection: ConnectionID) {
        guard let id = linkByConnection[connection], let link = links[id] else { return }
        links[id]?.unflushed = 0
        guard !link.writable else { return }
        links[id]?.writable = true
        resumeWritabilityWaiters(id, writable: true)
    }

    /// The direct link whose send buffer decides whether `link` can send:
    /// itself, or its carrier's.
    func readinessLink(for id: LinkID) -> LinkID? {
        guard let link = links[id] else { return nil }
        switch link.transport {
        case .direct:
            return id
        case .relayed(let routeID, let carrier):
            guard installedRoutes[routeID]?.carrier == carrier else { return nil }
            return directRelayCarrierSession(for: carrier)?.link
        }
    }

    mutating func waitUntilWritable(_ id: LinkID, for request: RequestID) {
        guard let target = readinessLink(for: id), let link = links[target] else {
            return complete(request, .writable(false))
        }
        guard !link.writable else { return complete(request, .writable(true)) }
        requests[request] = .writable(target)
        writabilityWaiters[target, default: []].append(.request(request))
    }

    /// Registers `waiter` for the link's next writability. False when the
    /// link is gone; the waiter is then not registered.
    mutating func awaitWritable(_ id: LinkID, _ waiter: WritabilityWaiter) -> Bool {
        guard let target = readinessLink(for: id) else { return false }
        writabilityWaiters[target, default: []].append(waiter)
        return true
    }

    mutating func removeWritabilityWaiter(_ waiter: WritabilityWaiter) {
        for (link, waiters) in writabilityWaiters where waiters.contains(waiter) {
            let rest = waiters.filter { $0 != waiter }
            writabilityWaiters[link] = rest.isEmpty ? nil : rest
        }
    }

    mutating func resumeWritabilityWaiters(_ id: LinkID, writable: Bool) {
        guard let waiters = writabilityWaiters.removeValue(forKey: id) else { return }
        for waiter in waiters {
            switch waiter {
            case .request(let request):
                if requests[request] != nil { complete(request, .writable(writable)) }
            case .serving(let request):
                servingBecameWritable(request, writable: writable)
            case .relayForward(let source):
                relayForwardBecameWritable(source, writable: writable)
            }
        }
    }
}
