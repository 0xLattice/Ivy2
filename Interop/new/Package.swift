// swift-tools-version: 6.0
import PackageDescription

// The interop program against this checkout.
let package = Package(
    name: "interop-new",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Ivy", path: "../.."),
        .package(url: "https://github.com/0xLattice/Tally.git", from: "3.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "node",
            dependencies: [
                .product(name: "Ivy", package: "Ivy"),
                "Tally",
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
    ]
)
