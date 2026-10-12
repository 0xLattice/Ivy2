// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ivy",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "Ivy", targets: ["Ivy"]),
        .library(name: "IvyCore", targets: ["IvyCore"]),
        .library(name: "IvySimulation", targets: ["IvySimulation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adalinxx/Tally.git", from: "3.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        // The protocol as a pure state machine: no sockets, tasks, clocks or awaits.
        .target(
            name: "IvyCore",
            dependencies: [
                "Tally",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        // The I/O shell: TCP, STUN, the timer, and the application-facing actor.
        .target(
            name: "Ivy",
            dependencies: [
                "IvyCore",
                "Tally",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
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
)
