import Crypto
import Foundation
import XCTest
@testable import IvyCore
import IvySimulation
import Tally

extension Simulation {
    /// A node with test defaults: no STUN, no keepalive unless asked for.
    @discardableResult
    func node(
        host: String? = nil,
        bootstrap: [PeerEndpoint] = [],
        carriers: [PeerEndpoint] = [],
        relayEnabled: Bool = false,
        mode: IvyMode = .overlay,
        health: PeerHealthConfig = PeerHealthConfig(enabled: false),
        requestTimeout: Duration = .seconds(15),
        maxConnections: Int = IvyConfig.defaultMaxConnections,
        maxConnectionsPerNetgroup: Int = 2,
        maxConcurrentContentRequests: Int = 64,
        maxOutstandingVolumeRequestsPerPeer: Int = 16,
        maxInboundBufferedBytes: Int = IvyConfig.defaultMaxInboundBufferedBytes,
        maxInFlightVolumeBytes: Int = IvyConfig.defaultMaxInFlightVolumeBytes,
        protocolMaxFrameSize: UInt32 = IvyConfig.defaultProtocolMaxFrameSize,
        privateContentExchangeEnabled: Bool = false,
        kBucketSize: Int = 20,
        start: Bool = true
    ) -> Node {
        let node = addNode(host: host) { key in
            IvyConfig(
                signingKey: key,
                listenPort: 4001,
                bootstrapPeers: bootstrap,
                kBucketSize: kBucketSize,
                requestTimeout: requestTimeout,
                stunServers: [],
                healthConfig: health,
                maxConnections: maxConnections,
                maxConnectionsPerNetgroup: maxConnectionsPerNetgroup,
                maxConcurrentContentRequests: maxConcurrentContentRequests,
                maxOutstandingVolumeRequestsPerPeer: maxOutstandingVolumeRequestsPerPeer,
                maxInboundBufferedBytes: maxInboundBufferedBytes,
                maxInFlightVolumeBytes: maxInFlightVolumeBytes,
                protocolMaxFrameSize: protocolMaxFrameSize,
                relayEnabled: relayEnabled,
                privateContentExchangeEnabled: privateContentExchangeEnabled,
                carriers: carriers,
                mode: mode)
        }
        if start { self.start(node) }
        return node
    }

    /// Connects `a` to `b` and runs until both sides see the session.
    func connect(_ a: Node, _ b: Node, file: StaticString = #filePath, line: UInt = #line) {
        let result = self.await(.connect(b.endpoint), on: a)
        XCTAssertEqual(result, .connect(.connected), file: file, line: line)
        run(until: { b.core.connectedPeers.contains(a.peer) && a.core.connectedPeers.contains(b.peer) })
        XCTAssertTrue(b.core.connectedPeers.contains(a.peer), file: file, line: line)
    }

    func session(_ a: Node, to b: Node) -> AuthenticatedPeer {
        a.core.authenticatedPeer(for: b.peer)!
    }
}

extension RequestResult {
    var content: AttributedContentResponse? {
        if case .content(let response) = self { return response }
        return nil
    }

    var volume: AttributedVolumeResponse? {
        if case .volume(let response) = self { return response }
        return nil
    }

    var bundle: AttributedVolumeBundleResponse? {
        if case .volumeBundle(let response) = self { return response }
        return nil
    }

    var endpoints: [PeerEndpoint]? {
        if case .endpoints(let endpoints) = self { return endpoints }
        return nil
    }

    var sent: SendMessageResult? {
        if case .send(let result) = self { return result }
        return nil
    }
}

func volumeEntries(root: String, members: Int, bytesEach: Int) -> [ContentEntry] {
    [ContentEntry(cid: root, data: Data(repeating: 0x01, count: bytesEach))]
        + (0..<members).map { ContentEntry(cid: "\(root)-\($0)", data: Data(repeating: UInt8($0 & 0xff), count: bytesEach)) }
}
