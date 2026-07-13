// swift-tools-version: 6.0
import PackageDescription

let architectureBranch = "agent/foundational-architecture-alignment"

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // Coordinated redesign stack. Each dependency PR is independently
        // reviewable; these branch pins make this top-level PR the integration
        // gate. Replace them with release tags before merging the series.
        .package(url: "https://github.com/adalinxx/Lattice.git", branch: architectureBranch),
        .package(url: "https://github.com/adalinxx/cashew.git", branch: architectureBranch),
        .package(url: "https://github.com/adalinxx/Tally.git", branch: architectureBranch),
        .package(url: "https://github.com/adalinxx/Ivy.git", branch: architectureBranch),
        .package(url: "https://github.com/adalinxx/VolumeBroker.git", branch: architectureBranch),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/swift-libp2p/swift-multihash.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "LatticeNodeAuth",
            dependencies: []),
        .target(
            name: "LatticeNodeWire",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
            ]),
        .target(
            name: "LatticeNodeRPCFuzzSupport",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .target(
            name: "LatticeLightClient",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
            ]),
        .executableTarget(
            name: "LatticeNode",
            dependencies: [
                "CSQLite",
                "LatticeLightClient",
                "LatticeNodeAuth",
                "LatticeNodeWire",
                "LatticeMinerCore",
                "LatticeNodeRPCFuzzSupport",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "CID", package: "swift-cid"),
            ]),
        .executableTarget(
            name: "LatticeProofVerifier",
            dependencies: [
                "LatticeLightClient",
            ]),
        .target(
            name: "LatticeMinerCore",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]),
        .target(
            name: "LatticeMiningCoordinator",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
            ]),
        .executableTarget(
            name: "LatticeMiningCoordinatorTool",
            dependencies: [
                "LatticeMiningCoordinator",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "LatticeMiner",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "P2PWireFuzz",
            dependencies: [
                "LatticeNodeWire",
                .product(name: "Ivy", package: "Ivy"),
            ],
            path: "FuzzTargets/P2PWireFuzz"),
        .executableTarget(
            name: "RPCRequestFuzz",
            dependencies: ["LatticeNodeRPCFuzzSupport"],
            path: "FuzzTargets/RPCRequestFuzz"),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: [
                "LatticeNode",
                "LatticeLightClient",
                "LatticeNodeAuth",
                "LatticeNodeWire",
                "LatticeNodeRPCFuzzSupport",
                "LatticeMinerCore",
                "LatticeMiningCoordinator",
                "CSQLite",
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "Multihash", package: "swift-multihash"),
                .product(name: "WAT", package: "WasmKit"),
            ]),
    ]
)
