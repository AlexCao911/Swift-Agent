// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let rustMacOSDebugLibraryPath = "\(packageDirectory)/../rust-core/target/debug"
// Xcode's scheme pre-action atomically stages the Rust archive for the active
// iOS SDK here. SwiftPM cannot distinguish iphoneos from iphonesimulator in a
// platform condition, so it must never hard-code either target triple.
let rustXcodeIOSLibraryPath = "\(packageDirectory)/../rust-core/target/xcode-ios"

let localAgentBridgeLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("local_ios_agent_runtime"),
    .linkedLibrary("c++"),
    .unsafeFlags(["-L\(rustMacOSDebugLibraryPath)"], .when(platforms: [.macOS])),
    .unsafeFlags(["-L\(rustXcodeIOSLibraryPath)"], .when(platforms: [.iOS])),
]

var packageTargets: [Target] = [
    .binaryTarget(
        name: "LocalAgentInferenceNative",
        path: "Artifacts/LocalAgentInferenceNative.xcframework"
    ),
    .systemLibrary(
        name: "CSQLite"
    ),
    .target(
        name: "CLocalAgentRuntime",
        publicHeadersPath: "include"
    ),
    .target(
        name: "LocalAgentBridge",
        dependencies: ["CLocalAgentRuntime", "LocalAgentLLMContracts"],
        linkerSettings: localAgentBridgeLinkerSettings
    ),
    .target(
        name: "LocalAgentLLMContracts"
    ),
    .target(
        name: "LocalAgentLLMCore",
        dependencies: ["LocalAgentLLMContracts", "CSQLite"]
    ),
    .target(
        name: "LocalAgentLLMLocal",
        dependencies: ["LocalAgentLLMContracts", "LocalAgentLLMCore", "CSQLite", "LocalAgentInferenceNative"],
        resources: [.process("Resources")],
        linkerSettings: [
            .linkedLibrary("c++"),
            .linkedFramework("Accelerate"),
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
        ]
    ),
    .target(
        name: "LocalAgentLLMCloud",
        dependencies: ["LocalAgentLLMContracts", "LocalAgentLLMCore", "CSQLite"],
        resources: [.process("Resources")],
        linkerSettings: [
            .linkedFramework("Security"),
        ]
    ),
    .target(
        name: "LocalAgentLLMHost",
        dependencies: [
            "LocalAgentBridge",
            "LocalAgentLLMContracts",
            "LocalAgentLLMCore",
            "LocalAgentLLMLocal",
            "LocalAgentLLMCloud",
        ],
        linkerSettings: [
            .linkedFramework("Security"),
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
        name: "LocalAgentLLMContractsTests",
        dependencies: ["LocalAgentLLMContracts"]
    ),
    .testTarget(
        name: "LocalAgentLLMCoreTests",
        dependencies: ["LocalAgentLLMCore", "LocalAgentLLMContracts"]
    ),
    .testTarget(
        name: "LocalAgentLLMLocalTests",
        dependencies: [
            "LocalAgentLLMContracts",
            "LocalAgentLLMCore",
            "LocalAgentLLMLocal",
        ],
        resources: [.process("Fixtures")]
    ),
    .testTarget(
        name: "LocalAgentLLMCloudTests",
        dependencies: [
            "LocalAgentLLMContracts",
            "LocalAgentLLMCore",
            "LocalAgentLLMCloud",
        ],
        resources: [.process("Fixtures")]
    ),
    .testTarget(
        name: "LocalAgentLLMHostTests",
        dependencies: [
            "LocalAgentBridge",
            "LocalAgentLLMContracts",
            "LocalAgentLLMHost",
        ]
    ),
    .testTarget(
        name: "LocalNativeToolkitTests",
        dependencies: ["LocalNativeToolkit"]
    ),
    .executableTarget(
        name: "LocalModelCatalogSigner",
        dependencies: ["LocalAgentLLMLocal"]
    ),
    .executableTarget(
        name: "CloudCapabilityCatalogSigner",
        dependencies: ["LocalAgentLLMCloud"]
    ),
    .executableTarget(
        name: "CloudProviderLiveSmoke",
        dependencies: [
            "LocalAgentLLMContracts",
            "LocalAgentLLMCore",
            "LocalAgentLLMCloud",
        ]
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
            type: .static,
            targets: ["LocalAgentBridge"]
        ),
        .library(
            name: "LocalAgentLLMContracts",
            targets: ["LocalAgentLLMContracts"]
        ),
        .library(
            name: "LocalAgentLLMCore",
            targets: ["LocalAgentLLMCore"]
        ),
        .library(
            name: "LocalAgentLLMLocal",
            type: .static,
            targets: ["LocalAgentLLMLocal"]
        ),
        .library(
            name: "LocalAgentLLMCloud",
            targets: ["LocalAgentLLMCloud"]
        ),
        .library(
            name: "LocalAgentLLMHost",
            targets: ["LocalAgentLLMHost"]
        ),
        .library(
            name: "LocalNativeToolkit",
            targets: ["LocalNativeToolkit"]
        ),
        .executable(
            name: "LocalModelCatalogSigner",
            targets: ["LocalModelCatalogSigner"]
        ),
        .executable(
            name: "CloudCapabilityCatalogSigner",
            targets: ["CloudCapabilityCatalogSigner"]
        ),
    ],
    targets: packageTargets
)
