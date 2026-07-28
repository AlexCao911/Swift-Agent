import Foundation
import LocalAgentLLMContracts

#if canImport(UIKit)
import UIKit
#endif

package struct LocalDeviceCapabilities: Equatable, Sendable {
    package let osMajor: Int
    package let deviceClass: LocalDeviceClass
    package let physicalMemoryBytes: UInt64

    package init(
        osMajor: Int,
        deviceClass: LocalDeviceClass,
        physicalMemoryBytes: UInt64
    ) {
        self.osMajor = osMajor
        self.deviceClass = deviceClass
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    @MainActor
    package static func current() -> Self {
        #if os(iOS)
        let deviceClass: LocalDeviceClass = UIDevice.current.userInterfaceIdiom == .pad
            ? .tablet : .phone
        #else
        let deviceClass: LocalDeviceClass = .tablet
        #endif
        return Self(
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            deviceClass: deviceClass,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}

package enum LocalModelCompatibility: Equatable, Sendable {
    case compatible
    case incompatible(code: String)
}

package struct LocalDeviceCompatibilityPolicy: Sendable {
    private static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    let device: LocalDeviceCapabilities

    package init(device: LocalDeviceCapabilities) {
        self.device = device
    }

    package func compatibility(
        of manifest: LocalModelRevisionManifest
    ) -> LocalModelCompatibility {
        guard device.osMajor >= manifest.minimumOSMajor else {
            return .incompatible(code: "download.os_unsupported")
        }
        guard manifest.supportedDeviceClasses.contains(device.deviceClass) else {
            return .incompatible(code: "download.device_unsupported")
        }
        guard device.physicalMemoryBytes >= minimumMemory(for: manifest.estimatedMemoryClass) else {
            return .incompatible(code: "download.memory_unsupported")
        }
        return .compatible
    }

    package func requireCompatibility(
        of manifest: LocalModelRevisionManifest
    ) throws {
        guard case let .incompatible(code) = compatibility(of: manifest) else {
            return
        }
        throw LLMFailure(
            code: code,
            message: "the signed model is not compatible with this device",
            retryable: false
        )
    }

    private func minimumMemory(for memoryClass: LocalMemoryClass) -> UInt64 {
        switch memoryClass {
        case .small:
            4 * Self.gibibyte
        case .medium:
            6 * Self.gibibyte
        case .large:
            12 * Self.gibibyte
        }
    }
}
