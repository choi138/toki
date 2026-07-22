// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TokiRemote",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "TokiUsageCore", targets: ["TokiUsageCore"]),
        .library(name: "TokiUsageReaders", targets: ["TokiUsageReaders"]),
        .library(name: "TokiSyncProtocol", targets: ["TokiSyncProtocol"]),
        .library(name: "TokiDurableStorage", targets: ["TokiDurableStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.5"),
    ],
    targets: [
        .target(name: "TokiUsageCore"),
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"]),
            ]),
        .target(name: "TokiDurableStorage"),
        .target(
            name: "TokiSyncProtocol",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .target(
            name: "TokiUsageReaders",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                "TokiDurableStorage",
                "TokiSyncProtocol",
                "TokiUsageCore",
            ]),
        .target(
            name: "TokiAgentCore",
            dependencies: [
                "TokiDurableStorage",
                "TokiSyncProtocol",
                "TokiUsageCore",
                "TokiUsageReaders",
            ]),
        .testTarget(
            name: "TokiSyncProtocolTests",
            dependencies: ["TokiSyncProtocol"]),
        .testTarget(
            name: "TokiAgentTests",
            dependencies: [
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
                "TokiAgentCore",
                "TokiDurableStorage",
                "TokiSyncProtocol",
                "TokiUsageCore",
                "TokiUsageReaders",
            ]),
    ])
