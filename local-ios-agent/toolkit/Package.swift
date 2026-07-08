// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let rustMacOSDebugLibraryPath = "\(packageDirectory)/../rust-core/target/debug"
let rustIOSSimulatorDebugLibraryPath = "\(packageDirectory)/../rust-core/target/aarch64-apple-ios-sim/debug"
let defaultLlamaCppXCFrameworkPath = URL(fileURLWithPath: packageDirectory)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("minicpmv-town/third_party/llama.cpp/build-apple/llama.xcframework")
    .path
let llamaCppXCFrameworkPath = ProcessInfo.processInfo.environment["LLAMA_CPP_XCFRAMEWORK"]
    ?? (FileManager.default.fileExists(atPath: defaultLlamaCppXCFrameworkPath)
        ? defaultLlamaCppXCFrameworkPath
        : nil)
let hasLlamaCppXCFramework = llamaCppXCFrameworkPath.map {
    FileManager.default.fileExists(atPath: $0)
} ?? false

var localAgentBridgeLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("local_ios_agent_runtime"),
    .linkedLibrary("c++"),
    .unsafeFlags(["-L\(rustMacOSDebugLibraryPath)"], .when(platforms: [.macOS])),
    .unsafeFlags(["-L\(rustIOSSimulatorDebugLibraryPath)"], .when(platforms: [.iOS])),
]
if hasLlamaCppXCFramework {
    let llamaCppXCFrameworkPath = llamaCppXCFrameworkPath!
    let macOSFrameworkSearchPath = "\(llamaCppXCFrameworkPath)/macos-arm64_x86_64"
    let iOSSimulatorFrameworkSearchPath = "\(llamaCppXCFrameworkPath)/ios-arm64_x86_64-simulator"
    localAgentBridgeLinkerSettings.append(
        .unsafeFlags([
            "-F\(macOSFrameworkSearchPath)",
            "-framework", "llama",
            "-Xlinker", "-rpath",
            "-Xlinker", macOSFrameworkSearchPath,
        ], .when(platforms: [.macOS]))
    )
    localAgentBridgeLinkerSettings.append(
        .unsafeFlags([
            "-F\(iOSSimulatorFrameworkSearchPath)",
            "-framework", "llama",
            "-Xlinker", "-rpath",
            "-Xlinker", iOSSimulatorFrameworkSearchPath,
        ], .when(platforms: [.iOS]))
    )
}

var packageTargets: [Target] = [
    .target(
        name: "CLocalAgentRuntime",
        publicHeadersPath: "include"
    ),
    .target(
        name: "LocalAgentBridge",
        dependencies: ["CLocalAgentRuntime"],
        linkerSettings: localAgentBridgeLinkerSettings
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
    targets: packageTargets
)
