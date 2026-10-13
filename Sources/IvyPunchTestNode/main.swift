// A node for Punch/run.sh, which puts two of these behind NATs of their own.
//
//   IvyPunchTestNode carrier <seed>
//   IvyPunchTestNode peer <seed> <carrier key>@<host>:<port> <public host> [<peer key>]
//
// `seed` is a signing key seed of 64 hex digits. A carrier relays, listens on
// port 4001 and runs until its standard input closes. A peer keeps a session
// with the carrier and offers `public host` as where it can be reached. Given
// a peer key it opens a relayed session to that peer; either way it waits for
// its session with the other peer to become direct, prints one line, DIRECT
// or RELAYED, and exits 0 or 1.

import Crypto
import Foundation
import Ivy
import Tally

func fail(_ reason: String) -> Never {
    FileHandle.standardError.write(Data("IvyPunchTestNode: \(reason)\n".utf8))
    exit(2)
}

func say(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
}

final class Sessions: IvyDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: AuthenticatedRoute] = [:]

    func route(to key: String) -> AuthenticatedRoute? { lock.withLock { routes[key] } }
    /// The endpoint this node has a session with, other than `carrier`.
    func peer(besides carrier: String) -> String? {
        lock.withLock { routes.keys.first { $0 != carrier } }
    }

    func ivy(_ ivy: Ivy, didConnect peer: AuthenticatedPeer) async {
        lock.withLock { routes[peer.key.hex] = peer.route }
        say("session \(peer.key.hex.prefix(8)) \(peer.route == .direct ? "direct" : "relayed")")
    }

    func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {
        lock.withLock { routes[peer.publicKey] = nil }
        say("disconnected \(peer.publicKey.prefix(8))")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, arguments[1].count == 64 else { fail("expected a role and a seed of 64 hex digits") }
let digits = Array(arguments[1])
let seed = stride(from: 0, to: 64, by: 2).compactMap { UInt8(String(digits[$0...($0 + 1)]), radix: 16) }
guard seed.count == 32, let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
else { fail("the seed is not hex") }

if arguments[0] == "carrier" {
    let config = IvyConfig(
        signingKey: signingKey, listenPort: 4001, stunServers: [],
        healthConfig: PeerHealthConfig(enabled: false), relayEnabled: true)
    let ivy = Ivy(config: config)
    do { try await ivy.start() } catch { fail("could not listen: \(error)") }
    say("carrier \(config.publicKey)")
    while readLine() != nil {}
    await ivy.stop()
    exit(0)
}

guard arguments[0] == "peer", arguments.count >= 4 else { fail("expected carrier or peer") }
let parts = arguments[2].split(whereSeparator: { $0 == "@" || $0 == ":" }).map(String.init)
guard parts.count == 3, let carrierPort = UInt16(parts[2]) else { fail("expected <carrier key>@<host>:<port>") }
let carrier = PeerEndpoint(publicKey: parts[0], host: parts[1], port: carrierPort)

let config = IvyConfig(
    signingKey: signingKey, listenPort: 4001, stunServers: [],
    healthConfig: PeerHealthConfig(enabled: false), carriers: [carrier])
let ivy = Ivy(config: config)
let sessions = Sessions()
var options = PunchConnector.Options()
options.hosts = [arguments[3]]
let punch = PunchConnector(ivy: ivy, localKey: config.publicKey, forwardingTo: sessions, options: options)
await ivy.setDelegate(punch)
do { try await ivy.start() } catch { fail("could not start: \(error)") }
say("peer \(config.publicKey)")

let clock = ContinuousClock()
func wait(_ seconds: Int, until condition: () -> Bool) async -> Bool {
    let deadline = clock.now + .seconds(seconds)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

guard await wait(20, until: { sessions.route(to: carrier.publicKey) != nil }) else { fail("no session with the carrier") }
if arguments.count > 4 {
    do {
        try await ivy.connectViaRelay(to: PeerEndpoint(publicKey: arguments[4], host: "relay", port: 0))
    } catch { fail("no relayed session: \(error)") }
}
guard await wait(60, until: { sessions.peer(besides: carrier.publicKey) != nil }),
      let other = sessions.peer(besides: carrier.publicKey) else { fail("no session with the other peer") }
let direct = await wait(40, until: { sessions.route(to: other) == .direct })
say(direct ? "DIRECT" : "RELAYED")
// Long enough for the other end to see the same.
try? await Task.sleep(for: .seconds(3))
await ivy.stop()
exit(direct ? 0 : 1)

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) { self.delegate = delegate }
}
