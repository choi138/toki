// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TokiHubPackage",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "toki-hub", targets: ["TokiHub"]),
    ],
    dependencies: [
        .package(name: "TokiRemote", path: ".."),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.117.2"),
    ],
    targets: [
        .target(
            name: "TokiHubCore",
            dependencies: [
                .product(name: "TokiDurableStorage", package: "TokiRemote"),
                .product(name: "TokiSyncProtocol", package: "TokiRemote"),
                .product(name: "Vapor", package: "vapor"),
            ]),
        .executableTarget(
            name: "TokiHub",
            dependencies: ["TokiHubCore"]),
        .testTarget(
            name: "TokiHubTests",
            dependencies: [
                "TokiHubCore",
                .product(name: "TokiSyncProtocol", package: "TokiRemote"),
                .product(name: "XCTVapor", package: "vapor"),
            ]),
    ])
