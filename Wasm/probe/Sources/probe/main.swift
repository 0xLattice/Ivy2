import Crypto
import IvyCore
import IvySimulation
import Tally

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Prints what a seeded network did, so two builds can be compared line for
// line. Nothing here may depend on wall-clock time.

func config(_ key: Curve25519.Signing.PrivateKey, bootstrap: [PeerEndpoint] = []) -> IvyConfig {
    IvyConfig(
        signingKey: key,
        listenPort: 4001,
        bootstrapPeers: bootstrap,
        stunServers: [],
        healthConfig: PeerHealthConfig(keepaliveInterval: .seconds(20), staleTimeout: .seconds(60)))
}

func entries(root: String, members: Int, bytesEach: Int) -> [ContentEntry] {
    [ContentEntry(cid: root, data: Data(repeating: 1, count: bytesEach))]
        + (0..<members).map {
            ContentEntry(cid: "\(root)-\($0)", data: Data(repeating: UInt8($0 & 0xff), count: bytesEach))
        }
}

/// Twelve nodes on simulated signatures: bootstrap, lookups, provider
/// records, Volume fetches, a node leaving and returning, and a partition.
func network(seed: UInt64) -> (digest: String, effects: Int, served: Int) {
    let sim = Simulation(seed: seed)
    let first = sim.addNode { config($0) }
    var nodes = [first]
    for _ in 0..<11 { nodes.append(sim.addNode { config($0, bootstrap: [first.endpoint]) }) }
    for node in nodes { sim.start(node) }
    sim.run(for: .seconds(5))

    for (index, node) in nodes.enumerated() where index % 3 == 0 {
        node.volumes["vol-\(index)"] = entries(root: "vol-\(index)", members: 6, bytesEach: 30_000)
        sim.send(.command(.announceProvider(
            rootCID: "vol-\(index)", expiresAt: sim.unixSeconds + 3_600)), to: node)
    }
    for node in nodes.dropFirst() { sim.request(.findNode(target: node.key.hex), on: node) }
    sim.run(for: .seconds(40))

    var fetches: [(Simulation.Node, RequestID)] = []
    for (index, node) in nodes.enumerated() where index % 3 != 0 {
        fetches.append((node, sim.request(.fetchVolume(
            rootCID: "vol-\(index - index % 3)", maximumArchiveBytes: .max, maximumEntries: .max),
            on: node)))
    }
    sim.run(for: .seconds(20))
    sim.stop(nodes[5])
    sim.setPartitioned(true, nodes[2], nodes[7])
    sim.run(for: .seconds(90))
    sim.start(nodes[5])
    sim.setPartitioned(false, nodes[2], nodes[7])
    sim.run(for: .seconds(150))

    let served = fetches.filter { node, request in
        if case .volume(let response)? = sim.result(of: request, on: node) {
            return !response.entries.isEmpty
        }
        return false
    }.count
    return (sim.traceDigest, sim.trace.count, served)
}

/// Two nodes on real Ed25519 signatures moving a Volume just under the
/// 64 MiB limit: the largest sizes and allocations the core handles.
func largestVolume() -> (entries: Int, bytes: Int) {
    let sim = Simulation(seed: 3)
    let quiet: (Curve25519.Signing.PrivateKey) -> IvyConfig = {
        IvyConfig(signingKey: $0, stunServers: [], healthConfig: PeerHealthConfig(enabled: false))
    }
    let a = sim.addNode(realSignatures: true, configure: quiet)
    let b = sim.addNode(realSignatures: true, configure: quiet)
    sim.start(a)
    sim.start(b)
    b.volumes["vol"] = entries(root: "vol", members: 63, bytesEach: 1024 * 1024 - 2048)
    _ = sim.await(.connect(b.endpoint), on: a)
    guard case .volume(let volume)? = sim.await(
        .fetchVolume(rootCID: "vol", maximumArchiveBytes: .max, maximumEntries: .max), on: a) else {
        return (0, 0)
    }
    return (volume.entries.count, volume.entries.values.reduce(0) { $0 + $1.count })
}

let seed = CommandLine.arguments.dropFirst().first.flatMap { UInt64($0) } ?? 0x5EED
let run = network(seed: seed)
print("network: seed=\(seed) effects=\(run.effects) served=\(run.served) digest=\(run.digest)")
print("network repeats: \(network(seed: seed).digest == run.digest)")
let volume = largestVolume()
print("ed25519 volume: entries=\(volume.entries) bytes=\(volume.bytes)")
