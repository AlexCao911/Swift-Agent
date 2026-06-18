// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalAgentIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LocalAgentBridge",
            targets: ["LocalAgentBridge"]
        ),
    ],
    targets: [
        .target(
            name: "CLocalAgentRuntime",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LocalAgentBridge",
            dependencies: ["CLocalAgentRuntime"]
        ),
        .testTarget(
            name: "LocalAgentBridgeTests",
            dependencies: ["LocalAgentBridge"]
        ),
    ]
)
