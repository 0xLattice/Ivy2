import Crypto
import Foundation
import Ivy
import Tally

// One program, built once against Ivy 15.0.1 and once against this checkout,
// so the two can be run against each other. See run.sh.
// usage: node listen <keyByte> <port>
//        node dial <keyByte> <port> <peerKeyByte> <peerPort>
setvbuf(stdout, nil, _IONBF, 0)

func key(_ byte: UInt8) -> Curve25519.Signing.PrivateKey {
    try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
}

struct Store: IvyContentSource {
    let tag: UInt8
    // 15.0.1's protocol requires this; this checkout has no such requirement.
    func content(rootCID: String, cids: [String], maxDataBytes: Int) async -> [ContentEntry] {
        guard rootCID == "root" else { return [] }
        return cids.map { ContentEntry(cid: $0, data: Data(($0 + "-\(tag)").utf8)) }
    }
    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        guard rootCID.hasPrefix("vol") else { return [] }
        return [ContentEntry(cid: rootCID, data: Data(repeating: tag, count: 100))]
            + (0..<10).map { ContentEntry(cid: "\(rootCID)-\($0)", data: Data(repeating: UInt8($0), count: 1024 * 1024)) }
    }
    func volumeBundle(rootCID: String) async -> [String] {
        rootCID == "vol" ? ["vol", "vol-b", "vol-c"] : []
    }
}

actor Box {
    var peers: [AuthenticatedPeer] = []
    var echoes: [PeerMessage] = []
    func add(_ peer: AuthenticatedPeer) { peers.append(peer) }
    func add(_ message: PeerMessage) { echoes.append(message) }
}

final class Echo: IvyDelegate, Sendable {
    let box = Box()
    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async { await box.add(peer) }
    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        if message.topic == "ping" {
            _ = await ivy.sendMessage(to: peer, topic: "echo", payload: message.payload)
        } else {
            await box.add(message)
        }
    }
}

extension Ivy {
    func use(_ delegate: IvyDelegate) { self.delegate = delegate }
}

func check(_ condition: Bool, _ what: String) {
    print(condition ? "ok   \(what)" : "FAIL \(what)")
    if !condition { exit(1) }
}

let args = CommandLine.arguments
let keyByte = UInt8(args[2])!
let port = UInt16(args[3])!
let ivy = Ivy(config: IvyConfig(
    signingKey: key(keyByte),
    listenPort: port,
    stunServers: [],
    maxConnectionsPerNetgroup: 8))
let echo = Echo()
await ivy.use(echo)
await ivy.setContentSource(Store(tag: keyByte))
try await ivy.start()

if args[1] == "listen" {
    print("listening")
    try await Task.sleep(nanoseconds: 60_000_000_000)
    exit(0)
}

let peerByte = UInt8(args[4])!
let peerKey = IvyConfig(signingKey: key(peerByte)).publicKey
let peerID = PeerID(publicKey: peerKey)
try await ivy.connect(to: PeerEndpoint(publicKey: peerKey, host: "127.0.0.1", port: UInt16(args[5])!))
check(await ivy.connectedPeers == [peerID], "session authenticated")

let payload = Data((0..<200_000).map { UInt8($0 & 0xff) })
let sent = await ivy.sendMessage(to: peerID, topic: "ping", payload: payload)
check(sent == .enqueued(endpoint: peerID, route: .direct), "message enqueued")
for _ in 0..<500 where await echo.box.echoes.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
check(await echo.box.echoes.first?.payload == payload, "message echoed back intact")

let session = await echo.box.peers.first!
let volume = await ivy.fetchVolume(rootCID: "vol", from: session)
check(volume.entries.count == 11 && volume.entries["vol"] == Data(repeating: peerByte, count: 100)
    && volume.entries["vol-9"] == Data(repeating: 9, count: 1024 * 1024) && volume.servedBy == peerID,
    "10 MiB Volume across frames")

let bundle = await ivy.fetchVolumeBundle(rootCID: "vol", from: [session])
check(bundle.volumes.map(\.rootCID) == ["vol", "vol-b", "vol-c"] && bundle.ended && !bundle.noBundle,
    "bundle of three Volumes, ended")
let none = await ivy.fetchVolumeBundle(rootCID: "vol-b", from: [session])
check(none.volumes.isEmpty && none.noBundle && none.ended, "no bundle for a root is said so")

let nodes = await ivy.findNode(target: "anything")
check(nodes.contains { $0.publicKey == peerKey }, "findNode sees the peer")
await ivy.announceProvider(rootCID: "vol", expiresAt: UInt64(Date().timeIntervalSince1970) + 600)
await ivy.stop()
print("PASS")
exit(0)
