// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TokiRemote",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "TokiUsageCore", targets: ["TokiUsageCore"]),
        .library(name: "TokiSyncProtocol", targets: ["TokiSyncProtocol"]),
        .library(name: "TokiDurableStorage", targets: ["TokiDurableStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.5"),
    ],
    targets: [
        .target(name: "TokiUsageCore"),
        .target(name: "TokiDurableStorage"),
        .target(
            name: "TokiSyncProtocol",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .testTarget(
            name: "TokiSyncProtocolTests",
            dependencies: ["TokiSyncProtocol"]),
    ])
