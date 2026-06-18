// swift-tools-version: 6.0

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
            dependencies: ["CLocalAgentRuntime"],
            linkerSettings: [
                .linkedLibrary("local_ios_agent_runtime"),
                .unsafeFlags(["-L../rust-core/target/debug"]),
            ]
        ),
        .testTarget(
            name: "LocalAgentBridgeTests",
            dependencies: ["LocalAgentBridge"]
        ),
    ]
)
