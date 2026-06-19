// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let rustMacOSDebugLibraryPath = "\(packageDirectory)/../rust-core/target/debug"
let rustIOSSimulatorDebugLibraryPath = "\(packageDirectory)/../rust-core/target/aarch64-apple-ios-sim/debug"

let package = Package(
    name: "LocalAgentToolkit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LocalAgentBridge",
            targets: ["LocalAgentBridge"]
        ),
        .library(
            name: "LocalNativeToolkit",
            targets: ["LocalNativeToolkit"]
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
                .linkedLibrary("c++"),
                .unsafeFlags(["-L\(rustMacOSDebugLibraryPath)"], .when(platforms: [.macOS])),
                .unsafeFlags(["-L\(rustIOSSimulatorDebugLibraryPath)"], .when(platforms: [.iOS])),
            ]
        ),
        .target(
            name: "LocalNativeToolkit",
            dependencies: ["LocalAgentBridge"]
        ),
        .testTarget(
            name: "LocalAgentBridgeTests",
            dependencies: ["LocalAgentBridge"]
        ),
        .testTarget(
            name: "LocalNativeToolkitTests",
            dependencies: ["LocalNativeToolkit"]
        ),
    ]
)
