// swift-tools-version: 6.0
import PackageDescription

// The interop program against the last release before the sans-IO rewrite.
let package = Package(
    name: "interop-old",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/adalinxx/Ivy.git", exact: "15.0.1"),
        .package(url: "https://github.com/adalinxx/Tally.git", from: "3.1.0"),
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
