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
    .package(url: "https://github.com/adalinxx/Tally.git", from: "3.1.0"),
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

if !coreOnly {
    products.insert(.library(name: "Ivy", targets: ["Ivy"]), at: 0)
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
    ]
}

let package = Package(
    name: "Ivy",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
