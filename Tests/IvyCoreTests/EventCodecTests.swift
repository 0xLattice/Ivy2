import Crypto
import Foundation
import XCTest
@testable import IvyCore
import Tally

/// The byte form of events and effects, which a JavaScript shell speaks.
final class EventCodecTests: XCTestCase {
    // MARK: - Samples

    private static func key(_ byte: UInt8) -> PeerKey {
        IvyConfig(signingKey: try! .init(rawRepresentation: Data(repeating: byte, count: 32))).peerKey
    }

    private static let direct = AuthenticatedPeer(
        key: key(1),
        role: .endpoint,
        route: .direct,
        metadata: PeerMetadata(),
        sessionID: Data(repeating: 0xa1, count: 32))

    private static let relayed = AuthenticatedPeer(
        key: key(2),
        role: .carrier,
        route: .relayed(carrier: key(3), routeID: Data(repeating: 0xb2, count: 16)),
        metadata: PeerMetadata(
            listenAddresses: [
                ListenAddress(host: "2001:db8::1", port: 4001),
                ListenAddress(host: "8.8.1.1", port: 4001),
                ListenAddress(host: "8.8.1.1", port: 4002),
            ],
            maxFrameSize: 1 << 20),
        sessionID: Data(repeating: 0xc3, count: 32))

    private static let endpoint = PeerEndpoint(publicKey: key(1).hex, host: "8.8.1.1", port: 4001)
    private static let peer = key(1).peerID
    private static let volume = AttributedVolumeResponse(
        rootCID: "root",
        entries: ["root": Data([1, 2, 3]), "root-0": Data(), "leaf": Data([0xff])],
        servedBy: peer)

    static let events: [(String, Event)] = [
        ("start", .start),
        ("stop", .stop),
        ("tick", .tick),
        ("connectionOpened: inbound, with both hosts",
         .connectionOpened(
            ConnectionID(7), direction: .inbound, observedHost: "8.8.1.1", localHost: "10.0.0.2")),
        ("connectionOpened: the answer to dial 9, hosts unknown",
         .connectionOpened(
            ConnectionID(.max), direction: .outbound(DialID(9)), observedHost: nil, localHost: nil)),
        ("dialFailed", .dialFailed(DialID(9))),
        ("received: four bytes", .received(ConnectionID(7), Data([0xde, 0xad, 0xbe, 0xef]))),
        ("received: nothing", .received(ConnectionID(7), Data())),
        ("writable", .writable(ConnectionID(7))),
        ("closed", .closed(ConnectionID(7))),
        ("request: connect", .request(RequestID(1), .connect(endpoint))),
        ("request: connectOver, observed host only",
         .request(RequestID(2), .connectOver(
            endpoint, ConnectionID(8), observedHost: "8.8.1.1", localHost: nil))),
        ("request: connectViaRelay", .request(RequestID(3), .connectViaRelay(endpoint))),
        ("request: send, with a topic outside ASCII",
         .request(RequestID(4), .send(to: peer, topic: "sync/é", payload: Data([1, 2, 3])))),
        ("request: sendOnSession, direct session",
         .request(RequestID(5), .sendOnSession(direct, topic: "t", payload: Data()))),
        ("request: waitUntilWritable", .request(RequestID(6), .waitUntilWritable(peer))),
        ("request: waitUntilSessionWritable, relayed session",
         .request(RequestID(7), .waitUntilSessionWritable(relayed))),
        ("request: fetchVolume, no limits",
         .request(RequestID(8), .fetchVolume(
            rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .max))),
        ("request: fetchVolume, limited",
         .request(RequestID(9), .fetchVolume(
            rootCID: "root", maximumArchiveBytes: 1 << 20, maximumEntries: 16))),
        ("request: fetchVolumeFrom",
         .request(RequestID(10), .fetchVolumeFrom(
            direct, rootCID: "root", maximumArchiveBytes: 4096, maximumEntries: 1))),
        ("request: fetchVolumeBundle, two sessions",
         .request(RequestID(11), .fetchVolumeBundle(rootCID: "root", from: [direct, relayed]))),
        ("request: fetchVolumeBundle, nobody named",
         .request(RequestID(12), .fetchVolumeBundle(rootCID: "root", from: []))),
        ("request: findNode", .request(RequestID(13), .findNode(target: key(4).hex))),
        ("request: discoverProviders", .request(RequestID(14), .discoverProviders(rootCID: "root"))),
        ("request: recycleSession", .request(RequestID(15), .recycleSession(direct))),
        ("request: disconnectSession", .request(RequestID(16), .disconnectSession(relayed))),
        ("request: fetchVolumeFromSessions, two sessions",
         .request(RequestID(17), .fetchVolumeFromSessions(
            [direct, relayed], rootCID: "root", maximumArchiveBytes: 4096, maximumEntries: 1))),
        ("request: fetchVolumeFromSessions, nobody named",
         .request(RequestID(18), .fetchVolumeFromSessions(
            [], rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .max))),
        ("cancel", .cancel(RequestID(8))),
        ("command: disconnect", .command(.disconnect(peer))),
        ("command: restartConfiguredSession", .command(.restartConfiguredSession(peer))),
        ("command: broadcast", .command(.broadcast(topic: "gossip", payload: Data([9, 8, 7])))),
        ("command: announceProvider",
         .command(.announceProvider(rootCID: "root", expiresAt: 1_800_000_000))),
        ("command: stopProviding", .command(.stopProviding(rootCID: "root"))),
        ("command: reportDeficientContent",
         .command(.reportDeficientContent(rootCID: "root", servedBy: peer))),
        ("command: setContentSource, present", .command(.setContentSource(true))),
        ("command: setContentSource, absent", .command(.setContentSource(false))),
        ("command: setRelaying", .command(.setRelaying(peer, true))),
        ("command: setRelaying, not", .command(.setRelaying(peer, false))),
        ("delivered", .delivered(DeliveryToken(21))),
        ("jobFinished: entries",
         .jobFinished(JobID(30), .entries([
            ContentEntry(cid: "root", data: Data([1, 2, 3])),
            ContentEntry(cid: "leaf", data: Data()),
         ]))),
        ("jobFinished: no entries", .jobFinished(JobID(31), .entries([]))),
        ("jobFinished: roots", .jobFinished(JobID(32), .roots(["root", "other"]))),
        ("jobFinished: authorized", .jobFinished(JobID(33), .authorized(true))),
        ("jobFinished: refused", .jobFinished(JobID(34), .authorized(false))),
        ("publicAddress: found", .publicAddress(ObservedAddress(host: "8.8.1.1", port: 4001))),
        ("publicAddress: not found", .publicAddress(nil)),
    ]

    static let effects: [(String, Effect)] = [
        ("dial", .dial(DialID(9), endpoint)),
        ("write", .write(ConnectionID(7), Data([0, 1, 2, 3, 4]))),
        ("close", .close(ConnectionID(7))),
        ("pauseReading", .pauseReading(ConnectionID(7))),
        ("resumeReading", .resumeReading(ConnectionID(7))),
        ("deliver: from a direct session",
         .deliver(DeliveryToken(21), direct, PeerMessage(topic: "sync", payload: Data([5, 6])))),
        ("deliver: from a relayed session, empty payload",
         .deliver(DeliveryToken(22), relayed, PeerMessage(topic: "", payload: Data()))),
        ("peerConnected", .peerConnected(DeliveryToken(23), direct)),
        ("peerDisconnected", .peerDisconnected(peer)),
        ("publicAddressDiscovered",
         .publicAddressDiscovered(ObservedAddress(host: "2001:db8::1", port: 443))),
        ("completed: connect, connected", .completed(RequestID(1), .connect(.connected))),
        ("completed: connect, cancelled", .completed(RequestID(1), .connect(.cancelled))),
        ("completed: connect, notRunning", .completed(RequestID(1), .connect(.failed(.notRunning)))),
        ("completed: connect, invalidPeerKey",
         .completed(RequestID(1), .connect(.failed(.invalidPeerKey)))),
        ("completed: connect, peerOutsideMode",
         .completed(RequestID(1), .connect(.failed(.peerOutsideMode)))),
        ("completed: connect, connectionInProgress",
         .completed(RequestID(1), .connect(.failed(.connectionInProgress)))),
        ("completed: connect, identityVerificationFailed",
         .completed(RequestID(1), .connect(.failed(.identityVerificationFailed)))),
        ("completed: connect, noRelayAvailable",
         .completed(RequestID(1), .connect(.failed(.noRelayAvailable)))),
        ("completed: connect, streamHasNoObservedHost",
         .completed(RequestID(1), .connect(.failed(.streamHasNoObservedHost)))),
        ("completed: send, enqueued on a direct route",
         .completed(RequestID(4), .send(.enqueued(endpoint: peer, route: .direct)))),
        ("completed: send, enqueued on a relayed route",
         .completed(RequestID(4), .send(.enqueued(
            endpoint: peer, route: .relayed(carrier: key(3), routeID: Data([1, 2, 3, 4])))))),
        ("completed: send, backpressured", .completed(RequestID(4), .send(.backpressured))),
        ("completed: send, notConnected", .completed(RequestID(4), .send(.notConnected))),
        ("completed: send, locallyRejected", .completed(RequestID(4), .send(.locallyRejected))),
        ("completed: writable", .completed(RequestID(6), .writable(true))),
        ("completed: not writable", .completed(RequestID(6), .writable(false))),
        ("completed: volume, three entries in identifier order",
         .completed(RequestID(8), .volume(volume))),
        ("completed: volume, empty", .completed(RequestID(8), .volume(.empty))),
        ("completed: volume, callerBoundaryExceeded",
         .completed(RequestID(8), .volume(AttributedVolumeResponse(
            rootCID: "", entries: [:], servedBy: nil, failure: .callerBoundaryExceeded)))),
        ("completed: volume, localCapacityUnavailable",
         .completed(RequestID(8), .volume(.localCapacityUnavailable))),
        ("completed: volume, notSent",
         .completed(RequestID(8), .volume(AttributedVolumeResponse(
            rootCID: "", entries: [:], servedBy: nil, failure: .notSent)))),
        ("completed: volumeBundle, two Volumes, ended",
         .completed(RequestID(11), .volumeBundle(AttributedVolumeBundleResponse(
            volumes: [
                volume,
                AttributedVolumeResponse(
                    rootCID: "other", entries: ["other": Data([7])], servedBy: peer),
            ],
            ended: true)))),
        ("completed: volumeBundle, the peer holds none",
         .completed(RequestID(11), .volumeBundle(AttributedVolumeBundleResponse(
            volumes: [], noBundle: true, ended: true)))),
        ("completed: volumeBundle, nobody asked",
         .completed(RequestID(11), .volumeBundle(.notSent))),
        ("completed: endpoints",
         .completed(RequestID(13), .endpoints([
            endpoint, PeerEndpoint(publicKey: key(2).hex, host: "2001:db8::1", port: 1),
         ]))),
        ("completed: no endpoints", .completed(RequestID(13), .endpoints([]))),
        ("completed: flag", .completed(RequestID(15), .flag(true))),
        ("startJob: readVolume", .startJob(JobID(30), .readVolume(rootCID: "root", maxDataBytes: 64 << 20))),
        ("startJob: readVolumeBundle", .startJob(JobID(32), .readVolumeBundle(rootCID: "root"))),
        ("startJob: authorizeVolume", .startJob(JobID(33), .authorizeVolume(relayed, rootCID: "root"))),
        ("cancelJob", .cancelJob(JobID(30))),
        ("discoverPublicAddress", .discoverPublicAddress),
        ("wakeAt: 90.5 seconds", .wakeAt(.milliseconds(90_500))),
        ("wakeAt: one nanosecond", .wakeAt(.nanoseconds(1))),
        ("wakeAt: zero", .wakeAt(.zero)),
    ]

    // MARK: - Coverage

    // These switches have no default on purpose: a new case stops this file
    // compiling until it is named here, and the counts below then fail until
    // it has a sample.

    private func name(_ event: Event) -> String {
        switch event {
        case .start: return "start"
        case .stop: return "stop"
        case .tick: return "tick"
        case .connectionOpened(_, .inbound, _, _): return "connectionOpened.inbound"
        case .connectionOpened(_, .outbound, _, _): return "connectionOpened.outbound"
        case .dialFailed: return "dialFailed"
        case .received: return "received"
        case .writable: return "writable"
        case .closed: return "closed"
        case .request(_, let request):
            switch request {
            case .connect: return "request.connect"
            case .connectOver: return "request.connectOver"
            case .connectViaRelay: return "request.connectViaRelay"
            case .send: return "request.send"
            case .sendOnSession: return "request.sendOnSession"
            case .waitUntilWritable: return "request.waitUntilWritable"
            case .waitUntilSessionWritable: return "request.waitUntilSessionWritable"
            case .fetchVolume: return "request.fetchVolume"
            case .fetchVolumeFrom: return "request.fetchVolumeFrom"
            case .fetchVolumeBundle: return "request.fetchVolumeBundle"
            case .findNode: return "request.findNode"
            case .discoverProviders: return "request.discoverProviders"
            case .recycleSession: return "request.recycleSession"
            case .disconnectSession: return "request.disconnectSession"
            case .fetchVolumeFromSessions: return "request.fetchVolumeFromSessions"
            }
        case .cancel: return "cancel"
        case .command(let command):
            switch command {
            case .disconnect: return "command.disconnect"
            case .restartConfiguredSession: return "command.restartConfiguredSession"
            case .broadcast: return "command.broadcast"
            case .announceProvider: return "command.announceProvider"
            case .stopProviding: return "command.stopProviding"
            case .reportDeficientContent: return "command.reportDeficientContent"
            case .setContentSource: return "command.setContentSource"
            case .setRelaying: return "command.setRelaying"
            }
        case .delivered: return "delivered"
        case .jobFinished(_, .entries): return "jobFinished.entries"
        case .jobFinished(_, .roots): return "jobFinished.roots"
        case .jobFinished(_, .authorized): return "jobFinished.authorized"
        case .publicAddress: return "publicAddress"
        }
    }

    private func name(_ effect: Effect) -> String {
        switch effect {
        case .dial: return "dial"
        case .write: return "write"
        case .close: return "close"
        case .pauseReading: return "pauseReading"
        case .resumeReading: return "resumeReading"
        case .deliver: return "deliver"
        case .peerConnected: return "peerConnected"
        case .peerDisconnected: return "peerDisconnected"
        case .publicAddressDiscovered: return "publicAddressDiscovered"
        case .completed(_, let result):
            switch result {
            case .connect(.connected): return "completed.connect.connected"
            case .connect(.cancelled): return "completed.connect.cancelled"
            case .connect(.failed(let error)):
                switch error {
                case .notRunning: return "completed.connect.notRunning"
                case .invalidPeerKey: return "completed.connect.invalidPeerKey"
                case .peerOutsideMode: return "completed.connect.peerOutsideMode"
                case .connectionInProgress: return "completed.connect.connectionInProgress"
                case .identityVerificationFailed:
                    return "completed.connect.identityVerificationFailed"
                case .noRelayAvailable: return "completed.connect.noRelayAvailable"
                case .streamHasNoObservedHost: return "completed.connect.streamHasNoObservedHost"
                }
            case .send(.enqueued(_, .direct)): return "completed.send.enqueued.direct"
            case .send(.enqueued(_, .relayed)): return "completed.send.enqueued.relayed"
            case .send(.backpressured): return "completed.send.backpressured"
            case .send(.notConnected): return "completed.send.notConnected"
            case .send(.locallyRejected): return "completed.send.locallyRejected"
            case .writable: return "completed.writable"
            case .volume(let response):
                switch response.failure {
                case nil: return "completed.volume"
                case .callerBoundaryExceeded: return "completed.volume.callerBoundaryExceeded"
                case .localCapacityUnavailable: return "completed.volume.localCapacityUnavailable"
                case .notSent: return "completed.volume.notSent"
                }
            case .volumeBundle: return "completed.volumeBundle"
            case .endpoints: return "completed.endpoints"
            case .flag: return "completed.flag"
            }
        case .startJob(_, .readVolume): return "startJob.readVolume"
        case .startJob(_, .readVolumeBundle): return "startJob.readVolumeBundle"
        case .startJob(_, .authorizeVolume): return "startJob.authorizeVolume"
        case .cancelJob: return "cancelJob"
        case .discoverPublicAddress: return "discoverPublicAddress"
        case .wakeAt: return "wakeAt"
        }
    }

    func testEveryCaseHasASample() {
        XCTAssertEqual(Set(Self.events.map { name($0.1) }).count, 38)
        XCTAssertEqual(Set(Self.effects.map { name($0.1) }).count, 37)
        XCTAssertEqual(Set(Self.events.map(\.0)).count, Self.events.count, "descriptions repeat")
        XCTAssertEqual(Set(Self.effects.map(\.0)).count, Self.effects.count, "descriptions repeat")
    }

    // MARK: - Round trips

    func testEveryEventRoundTrips() {
        for (description, event) in Self.events {
            let bytes = event.encoded()
            XCTAssertEqual(bytes.first, EventCodec.version, description)
            XCTAssertEqual(Event(encoded: bytes), event, description)
        }
    }

    func testEveryEffectRoundTrips() {
        for (description, effect) in Self.effects {
            XCTAssertEqual(Effect(encoded: effect.encoded()), effect, description)
        }
        let all = Self.effects.map(\.1)
        XCTAssertEqual(Effect.decodeList(Effect.encoded(all)), all)
        XCTAssertEqual(Effect.decodeList(Effect.encoded([])), [])
    }

    func testALargePayloadIsCarriedAsItIs() {
        let payload = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let bytes = Event.received(ConnectionID(1), payload).encoded()
        // Version, tag, connection, length: nothing else is added.
        XCTAssertEqual(bytes.count, payload.count + 14)
        XCTAssertEqual(Event(encoded: bytes), .received(ConnectionID(1), payload))
    }

    func testListsOfPeersAndEndpointsRoundTrip() {
        let peers = [Self.key(1).peerID, Self.key(2).peerID]
        XCTAssertEqual(EventCodec.decodePeers(EventCodec.encoded(peers: peers)), peers)
        XCTAssertEqual(EventCodec.decodePeers(EventCodec.encoded(peers: [])), [])
        let endpoints = [Self.endpoint, PeerEndpoint(publicKey: "", host: "", port: 0)]
        XCTAssertEqual(
            EventCodec.decodeEndpoints(EventCodec.encoded(endpoints: endpoints)), endpoints)
    }

    /// Sizes are `Int` in the core and 64 bits on the wire, so "no limit"
    /// from a 64-bit host is still no limit where `Int` is 32 bits.
    func testASizeBeyondIntIsClamped() {
        var writer = CodecWriter()
        writer.uint8(8)
        writer.uint64(1)
        writer.uint8(7)
        writer.string("root")
        writer.int64(.max)
        writer.int64(.min)
        XCTAssertEqual(
            Event(encoded: writer.bytes),
            .request(RequestID(1), .fetchVolume(
                rootCID: "root", maximumArchiveBytes: .max, maximumEntries: .min)))
    }

    // MARK: - Rejection

    func testTruncatedAndExtendedInputIsRejected() {
        for (description, event) in Self.events {
            let bytes = event.encoded()
            for length in 0..<bytes.count {
                XCTAssertNil(Event(encoded: bytes.prefix(length)), "\(description) cut to \(length)")
            }
            XCTAssertNil(Event(encoded: bytes + [0]), description)
        }
        for (description, effect) in Self.effects {
            let bytes = effect.encoded()
            for length in 0..<bytes.count {
                XCTAssertNil(Effect(encoded: bytes.prefix(length)), "\(description) cut to \(length)")
            }
            XCTAssertNil(Effect(encoded: bytes + [0]), description)
        }
        let list = Effect.encoded(Self.effects.map(\.1))
        XCTAssertNil(Effect.decodeList(list.dropLast()))
        XCTAssertNil(Effect.decodeList(list + [0]))
    }

    /// A slice does not start at index zero; the reader must not assume it.
    func testASliceDecodes() {
        let bytes = Data([0xff, 0xff]) + Event.dialFailed(DialID(9)).encoded()
        XCTAssertEqual(Event(encoded: bytes.dropFirst(2)), .dialFailed(DialID(9)))
    }

    func testMalformedInputIsRejected() {
        func event(_ build: (inout CodecWriter) -> Void) -> Event? {
            var writer = CodecWriter()
            build(&writer)
            return Event(encoded: writer.bytes)
        }
        func effect(_ build: (inout CodecWriter) -> Void) -> Effect? {
            var writer = CodecWriter()
            build(&writer)
            return Effect(encoded: writer.bytes)
        }

        XCTAssertNil(Event(encoded: Data()))
        XCTAssertNil(Event(encoded: Data([0, 0])), "version 0")
        XCTAssertNil(Event(encoded: Data([EventCodec.version + 1, 0])), "the next version")
        XCTAssertNil(event { $0.uint8(14) }, "unknown event")
        XCTAssertNil(effect { $0.uint8(14) }, "unknown effect")
        XCTAssertNil(event { $0.uint8(8); $0.uint64(1); $0.uint8(14) }, "unknown request")
        XCTAssertNil(event { $0.uint8(10); $0.uint8(6) }, "unknown command")
        XCTAssertNil(event { $0.uint8(12); $0.uint64(1); $0.uint8(3) }, "unknown job result")
        XCTAssertNil(event { $0.uint8(10); $0.uint8(5); $0.uint8(2) }, "a Bool that is neither")
        XCTAssertNil(event { $0.uint8(13); $0.uint8(2) }, "an optional that is neither")
        XCTAssertNil(
            event { $0.uint8(3); $0.uint64(1); $0.uint8(2); $0.uint8(0); $0.uint8(0) },
            "unknown direction")

        // Lengths and counts far beyond the input, which must not be
        // allocated for or turned into an `Int` that cannot hold them.
        XCTAssertNil(event { $0.uint8(5); $0.uint64(1); $0.uint32(.max) })
        XCTAssertNil(event { $0.uint8(5); $0.uint64(1); $0.uint32(0x8000_0000); $0.uint8(0) })
        XCTAssertNil(event { $0.uint8(10); $0.uint8(2); $0.uint32(.max) })
        XCTAssertNil(event { $0.uint8(12); $0.uint64(1); $0.uint8(1); $0.uint32(.max) })
        XCTAssertNil(effect { $0.uint8(9); $0.uint64(1); $0.uint8(5); $0.uint32(.max) })
        XCTAssertNil(Effect.decodeList(Data([EventCodec.version, 0xff, 0xff, 0xff, 0xff])))

        // Bytes that are not UTF-8, and bytes that are but that Swift would
        // otherwise repair or reorder.
        XCTAssertNil(event { $0.uint8(10); $0.uint8(2); $0.data(Data([0xff])); $0.data(Data()) })
        XCTAssertNil(event { $0.uint8(10); $0.uint8(2); $0.data(Data([0xc0, 0x80])); $0.data(Data()) })
        XCTAssertEqual(
            event { $0.uint8(10); $0.uint8(2); $0.data(Data([0xef, 0xbb, 0xbf])); $0.data(Data()) },
            .command(.broadcast(topic: "\u{FEFF}", payload: Data())),
            "a byte-order mark is part of the string")

        // A peer key is exactly 32 bytes, and a role and a route are known.
        XCTAssertNil(effect { $0.uint8(6); $0.uint64(1); $0.uint8(0) })
        let peer = Effect.peerConnected(DeliveryToken(1), Self.direct).encoded()
        var badRole = peer
        badRole[badRole.startIndex + 10 + 32] = 2
        XCTAssertNil(Effect(encoded: badRole))
        var badRoute = peer
        badRoute[badRoute.startIndex + 10 + 33] = 2
        XCTAssertNil(Effect(encoded: badRoute))

        // One value has one encoding.
        XCTAssertNil(effect { $0.uint8(13); $0.int64(0); $0.int64(1_000_000_000_000_000_000) })
        XCTAssertNil(effect { $0.uint8(13); $0.int64(1); $0.int64(-1) })
        XCTAssertEqual(effect { $0.uint8(13); $0.int64(-1); $0.int64(-5) }, .wakeAt(.seconds(-1) - .nanoseconds(5) / 1_000_000_000))
        func volume(_ cids: [String]) -> Effect? {
            effect {
                $0.uint8(9); $0.uint64(1); $0.uint8(3)
                $0.string("root")
                $0.list(cids) { $0.string($1); $0.data(Data()) }
                $0.uint8(0); $0.uint8(0)
            }
        }
        XCTAssertNotNil(volume(["a", "b"]))
        XCTAssertNil(volume(["b", "a"]), "entries out of order")
        XCTAssertNil(volume(["a", "a"]), "an entry twice")
        XCTAssertNil(volume(["e\u{301}", "\u{e9}"]), "two spellings Swift holds equal")
        func addresses(_ list: [ListenAddress]) -> Effect? {
            effect {
                $0.uint8(6); $0.uint64(1)
                $0.fixedForTesting(Self.key(1).rawRepresentation)
                $0.uint8(0); $0.uint8(0)
                $0.list(list) { $0.string($1.host); $0.uint16($1.port) }
                $0.uint32(1); $0.data(Data())
            }
        }
        let first = ListenAddress(host: "a", port: 1), second = ListenAddress(host: "b", port: 1)
        XCTAssertNotNil(addresses([first, second]))
        XCTAssertNil(addresses([second, first]), "addresses out of order")
        XCTAssertNil(addresses([first, first]), "an address twice")
    }

    /// Whatever the bytes, decoding answers; it does not trap.
    func testCorruptedInputNeverTraps() {
        var random = CoreRandom.seeded(0x5eed)
        var decoded = 0
        for bytes in Self.events.map({ $0.1.encoded() }) + Self.effects.map({ $0.1.encoded() }) {
            for index in bytes.indices {
                for value: UInt8 in [0, 1, 0x7f, 0x80, 0xff, UInt8(truncatingIfNeeded: random.next())] {
                    var corrupted = bytes
                    corrupted[index] = value
                    if Event(encoded: corrupted) != nil { decoded += 1 }
                    if Effect(encoded: corrupted) != nil { decoded += 1 }
                    if Effect.decodeList(corrupted) != nil { decoded += 1 }
                    if IvyConfig(encoded: corrupted) != nil { decoded += 1 }
                }
            }
        }
        for _ in 0..<2_000 {
            let length = Int(random.below(64))
            let bytes = Data([EventCodec.version] + (0..<length).map { _ in
                UInt8(truncatingIfNeeded: random.next())
            })
            if Event(encoded: bytes) != nil { decoded += 1 }
            if Effect(encoded: bytes) != nil { decoded += 1 }
        }
        XCTAssertGreaterThan(decoded, 0)
    }

    // MARK: - Configuration

    private func config(_ fields: [Int: (inout CodecWriter) -> Void] = [:]) -> IvyConfig? {
        var writer = CodecWriter()
        writer.fixedForTesting(Data(repeating: 1, count: 32))
        for index in 0..<18 {
            guard let field = fields[index] else {
                writer.uint8(0)
                continue
            }
            writer.uint8(1)
            field(&writer)
        }
        return IvyConfig(encoded: writer.bytes)
    }

    func testAConfigurationOfOnlyAKeyHasTheDefaults() throws {
        let config = try XCTUnwrap(config())
        let defaults = IvyConfig(
            signingKey: try .init(rawRepresentation: Data(repeating: 1, count: 32)))
        XCTAssertEqual(config.peerKey, defaults.peerKey)
        XCTAssertEqual(config.listenPort, defaults.listenPort)
        XCTAssertEqual(config.bootstrapPeers, [])
        XCTAssertEqual(config.carriers, [])
        XCTAssertEqual(config.relayEnabled, defaults.relayEnabled)
        XCTAssertEqual(config.mode, .overlay)
        XCTAssertEqual(config.privateContentExchangeEnabled, false)
        XCTAssertEqual(config.requestTimeout, defaults.requestTimeout)
        XCTAssertEqual(config.healthConfig.keepaliveInterval, defaults.healthConfig.keepaliveInterval)
        XCTAssertEqual(config.healthConfig.staleTimeout, defaults.healthConfig.staleTimeout)
        XCTAssertEqual(config.healthConfig.maxMissedPongs, defaults.healthConfig.maxMissedPongs)
        XCTAssertEqual(config.healthConfig.enabled, true)
        XCTAssertEqual(config.protocolMaxFrameSize, defaults.protocolMaxFrameSize)
        XCTAssertEqual(config.maxConnections, defaults.maxConnections)
        XCTAssertEqual(config.maxConnectionsPerNetgroup, defaults.maxConnectionsPerNetgroup)
        XCTAssertEqual(config.maxPendingRequests, defaults.maxPendingRequests)
        XCTAssertEqual(config.maxConcurrentContentRequests, defaults.maxConcurrentContentRequests)
        XCTAssertEqual(config.maxInboundBufferedBytes, defaults.maxInboundBufferedBytes)
        XCTAssertEqual(config.maxInFlightVolumeBytes, defaults.maxInFlightVolumeBytes)
        // Nothing here can ask a STUN server, so the core is not told of any.
        XCTAssertTrue(config.stunServers.isEmpty)
        XCTAssertNoThrow(try config.validate())
    }

    func testEveryConfigurationFieldIsRead() throws {
        let bootstrap = PeerEndpoint(publicKey: Self.key(2).hex, host: "8.8.2.1", port: 4001)
        let carrier = PeerEndpoint(publicKey: Self.key(3).hex, host: "8.8.3.1", port: 4002)
        let config = try XCTUnwrap(config([
            0: { $0.uint16(0) },
            1: { $0.list([bootstrap]) { $0.endpoint($1) } },
            2: { $0.list([carrier]) { $0.endpoint($1) } },
            3: { $0.bool(true) },
            4: { $0.uint8(2); $0.string(Self.key(2).hex) },
            5: { $0.bool(true) },
            6: { $0.duration(.milliseconds(2_500)) },
            7: { $0.duration(.seconds(5)) },
            8: { $0.duration(.seconds(20)) },
            9: { $0.int64(7) },
            10: { $0.bool(false) },
            11: { $0.uint32(1 << 20) },
            12: { $0.int64(11) },
            13: { $0.int64(12) },
            14: { $0.int64(13) },
            15: { $0.int64(14) },
            16: { $0.int64(15 << 20) },
            17: { $0.int64(16 << 20) },
        ]))
        XCTAssertEqual(config.listenPort, 0)
        XCTAssertEqual(config.bootstrapPeers, [bootstrap])
        XCTAssertEqual(config.carriers, [carrier])
        XCTAssertEqual(config.relayEnabled, true)
        XCTAssertEqual(config.mode, .pinned(peer: Self.key(2).hex))
        XCTAssertEqual(config.privateContentExchangeEnabled, true)
        XCTAssertEqual(config.requestTimeout, .milliseconds(2_500))
        XCTAssertEqual(config.healthConfig.keepaliveInterval, .seconds(5))
        XCTAssertEqual(config.healthConfig.staleTimeout, .seconds(20))
        XCTAssertEqual(config.healthConfig.maxMissedPongs, 7)
        XCTAssertEqual(config.healthConfig.enabled, false)
        XCTAssertEqual(config.protocolMaxFrameSize, 1 << 20)
        XCTAssertEqual(config.maxConnections, 11)
        XCTAssertEqual(config.maxConnectionsPerNetgroup, 12)
        XCTAssertEqual(config.maxPendingRequests, 13)
        XCTAssertEqual(config.maxConcurrentContentRequests, 14)
        XCTAssertEqual(config.maxInboundBufferedBytes, 15 << 20)
        XCTAssertEqual(config.maxInFlightVolumeBytes, 16 << 20)
        XCTAssertNoThrow(try config.validate())

        XCTAssertEqual(self.config([4: { $0.uint8(0) }])?.mode, .overlay)
        XCTAssertEqual(self.config([4: { $0.uint8(1) }])?.mode, .privateNetwork)
    }

    func testAMalformedConfigurationIsRejected() throws {
        var writer = CodecWriter()
        writer.fixedForTesting(Data(repeating: 1, count: 32))
        for _ in 0..<18 { writer.uint8(0) }
        let bytes = writer.bytes
        XCTAssertNotNil(IvyConfig(encoded: bytes))
        for length in 0..<bytes.count {
            XCTAssertNil(IvyConfig(encoded: bytes.prefix(length)), "cut to \(length)")
        }
        XCTAssertNil(IvyConfig(encoded: bytes + [0]))
        XCTAssertNil(IvyConfig(encoded: Data([EventCodec.version + 1]) + bytes.dropFirst()), "another version")
        XCTAssertNil(config([4: { $0.uint8(3) }]), "unknown mode")
        XCTAssertNil(config([1: { $0.uint32(.max) }]), "a count beyond the input")
        // A limit beyond `Int` is the largest one, and is left for
        // `validate()` to accept or refuse.
        XCTAssertEqual(config([12: { $0.int64(.max) }])?.maxConnections, Int(clamping: Int64.max))
        XCTAssertThrowsError(try XCTUnwrap(config([12: { $0.int64(0) }])).validate())
    }

    // MARK: - Golden vectors

    private static func hex(_ bytes: Data) -> String {
        bytes.map { hexByte($0) }.joined()
    }

    /// The file a TypeScript test decodes and encodes again: what keeps the
    /// two codecs from drifting.
    static var vectors: String {
        func section(_ name: String, _ vectors: [(String, Data)]) -> String {
            let lines = vectors.map {
                "    { \"description\": \"\($0.0)\", \"hex\": \"\(hex($0.1))\" }"
            }
            return "  \"\(name)\": [\n" + lines.joined(separator: ",\n") + "\n  ]"
        }
        return "{\n  \"version\": \(EventCodec.version),\n"
            + section("events", events.map { ($0.0, $0.1.encoded()) }) + ",\n"
            + section("effects", effects.map { ($0.0, $0.1.encoded()) }) + "\n}\n"
    }

#if !os(WASI)
    /// Set IVY_UPDATE_VECTORS=1 to rewrite the file after a deliberate change.
    func testGoldenVectorsMatchTheCheckedInFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Web/test/vectors.json")
        if ProcessInfo.processInfo.environment["IVY_UPDATE_VECTORS"] == "1" {
            try Data(Self.vectors.utf8).write(to: file)
        }
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), Self.vectors,
            "Web/test/vectors.json is out of date; see this test's comment")
    }
#endif
}

private extension CodecWriter {
    /// Bytes with no length before them, as a key is written.
    mutating func fixedForTesting(_ value: Data) {
        for byte in value { uint8(byte) }
    }
}
