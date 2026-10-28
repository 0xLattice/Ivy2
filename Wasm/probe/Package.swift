// swift-tools-version: 6.0
import PackageDescription

// A program built once natively and once for WebAssembly. Equal output is
// the evidence that the core behaves the same on both. See ../run.sh.
let package = Package(
    name: "ivy-wasm-probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Ivy", path: "../.."),
        .package(url: "https://github.com/0xLattice/Tally.git", from: "3.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "probe",
            dependencies: [
                .product(name: "IvyCore", package: "Ivy"),
                .product(name: "IvySimulation", package: "Ivy"),
                "Tally",
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
    ]
)
