// swift-tools-version: 6.0
import PackageDescription

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// The core and the simulator build for WebAssembly; the shell does not,
// because SwiftNIO does not. `IVY_CORE_ONLY=1` leaves the shell and its
// dependency out, which is how the core is built and tested as Wasm.
let coreOnly = ProcessInfo.processInfo.environment["IVY_CORE_ONLY"] == "1"

var products: [Product] = [
    .library(name: "IvyCore", targets: ["IvyCore"]),
    .library(name: "IvySimulation", targets: ["IvySimulation"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/0xLattice/Tally.git", from: "3.2.0"),
    // From 4.0 swift-crypto needs only FoundationEssentials, which keeps a
    // WebAssembly build small; the 3.x line still works everywhere else.
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
]

var targets: [Target] = [
    // The protocol as a pure state machine: no sockets, tasks, clocks or awaits.
    .target(
        name: "IvyCore",
        dependencies: [
            "Tally",
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
    // Drives many cores over a simulated network on virtual time.
    .target(
        name: "IvySimulation",
        dependencies: [
            "IvyCore",
            "Tally",
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
    .testTarget(
        name: "IvyCoreTests",
        dependencies: [
            "IvyCore",
            "IvySimulation",
            "Tally",
            .product(name: "Crypto", package: "swift-crypto"),
        ]
    ),
]

if coreOnly {
    // The core behind a C ABI, for a JavaScript shell. A reactor has no
    // `main` to run: its exports are called for as long as the host likes.
    targets.append(.executableTarget(
        name: "IvyWasm",
        dependencies: ["IvyCore"],
        linkerSettings: [
            .unsafeFlags(["-Xclang-linker", "-mexec-model=reactor"], .when(platforms: [.wasi])),
        ]
    ))
} else {
    products.insert(.library(name: "Ivy", targets: ["Ivy"]), at: 0)
    products.insert(.library(name: "IvyWebSocket", targets: ["IvyWebSocket"]), at: 1)
    dependencies.append(.package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"))
    targets += [
        // The I/O shell: connections, STUN, the timer, and the application-facing actor.
        .target(
            name: "Ivy",
            dependencies: [
                "IvyCore",
                "Tally",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // Ivy over a WebSocket, for peers that cannot open a TCP connection.
        .target(
            name: "IvyWebSocket",
            dependencies: [
                "Ivy",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        // A node for Web/'s tests to reach over a real WebSocket.
        .executableTarget(
            name: "IvyWebSocketTestNode",
            dependencies: [
                "IvyWebSocket",
                "Ivy",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // A node for Punch/run.sh to put behind a NAT.
        .executableTarget(
            name: "IvyPunchTestNode",
            dependencies: [
                "Ivy",
                "Tally",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "IvyTests",
            dependencies: [
                "Ivy",
                "Tally",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "IvyWebSocketTests",
            dependencies: [
                "IvyWebSocket",
                "Ivy",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
}

let package = Package(
    name: "Ivy",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
