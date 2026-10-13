// A node for Web/'s tests to reach over a real WebSocket.
//
//   IvyWebSocketTestNode <signing key seed, 64 hex digits> [--relay]
//
// With `--relay` it also carries sessions between its peers, as the node two
// pages meet through does.
//
// It listens on a loopback port of the system's choosing and prints one line
// of JSON naming it: {"publicKey":"…","port":…}. It serves two Volumes whose
// bytes a test can make again, sends every message back on its topic, and
// exits when its standard input closes.

import Crypto
import Foundation
import Ivy
import IvyWebSocket

/// `small` is one entry; `large` is its root and twelve entries of 1 MiB.
/// Byte `offset` of entry `index` is `(offset * 31 + index) & 0xff`.
struct Volumes: IvyContentSource {
    static func entry(_ cid: String, index: Int, count: Int) -> ContentEntry {
        ContentEntry(cid: cid, data: Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) }))
    }

    let volumes: [String: [ContentEntry]] = [
        "small": [entry("small", index: 0, count: 512)],
        "large": [entry("large", index: 0, count: 512)]
            + (1...12).map { entry("large-\($0)", index: $0, count: 1024 * 1024) },
    ]

    func volume(rootCID: String, maxDataBytes: Int) async -> [ContentEntry] {
        volumes[rootCID] ?? []
    }
}

final class Echo: IvyDelegate {
    func ivy(_ ivy: Ivy, didReceiveMessage message: PeerMessage, from peer: AuthenticatedPeer) async {
        // The peer's next message waits here while its echo has no room.
        while await ivy.sendMessage(to: peer, topic: message.topic, payload: message.payload) == .backpressured,
              await ivy.waitUntilWritable(to: peer) {}
    }
}

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("IvyWebSocketTestNode: \(reason)\n".utf8))
    exit(2)
}

let digits = Array(CommandLine.arguments.dropFirst().first ?? "")
guard digits.count == 64 else { fail("expected a signing key seed of 64 hex digits") }
let seed = stride(from: 0, to: 64, by: 2).map { UInt8(String(digits[$0...($0 + 1)]), radix: 16) }
guard !seed.contains(nil),
      let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed.compactMap { $0 }))
else { fail("the seed is not hex") }

let config = IvyConfig(
    signingKey: signingKey,
    listenPort: 0,
    stunServers: [],
    healthConfig: PeerHealthConfig(enabled: false),
    // Every test connects from the loopback address.
    maxConnectionsPerNetgroup: 16,
    relayEnabled: CommandLine.arguments.dropFirst(2).contains("--relay"))
let ivy = Ivy(config: config)
let echo = Echo()
await ivy.setDelegate(echo)
await ivy.setContentSource(Volumes())
let listener = WebSocketTransport(ivy: ivy)
do {
    try await ivy.start()
    try await listener.listen(host: "127.0.0.1", port: 0)
} catch {
    fail("could not listen: \(error)")
}
guard let port = listener.boundPort else { fail("the listener has no port") }
FileHandle.standardOutput.write(Data(#"{"publicKey":"\#(config.publicKey)","port":\#(port)}\#n"#.utf8))

while readLine() != nil {}
await listener.stopListening()
await ivy.stop()

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) { self.delegate = delegate }
}
