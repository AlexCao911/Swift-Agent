import Foundation
import LocalAgentLLMContracts

public struct LocalStorageRequirement: Equatable, Sendable {
    public let remainingDownloadBytes: UInt64
    public let verificationOverheadBytes: UInt64
    public let safetyReserveBytes: UInt64

    public var totalRequiredBytes: UInt64 {
        remainingDownloadBytes + verificationOverheadBytes + safetyReserveBytes
    }
}

package struct LocalDiskReservation: Equatable, Sendable {
    let reservationID: String
    let installationID: String
    let reservedBytes: UInt64
}

package protocol LocalVolumeCapacity: Sendable {
    func availableImportantUsageBytes(at root: URL) throws -> UInt64
}

package struct SystemLocalVolumeCapacity: LocalVolumeCapacity {
    package func availableImportantUsageBytes(at root: URL) throws -> UInt64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let signed = values.volumeAvailableCapacityForImportantUsage, signed >= 0 else {
            throw diskFailure("download.capacity_unavailable", "important-usage disk capacity is unavailable")
        }
        return UInt64(signed)
    }
}

package struct LocalDiskPolicy: Sendable {
    private let store: LocalModelStore
    private let root: URL

    package init(store: LocalModelStore, root: URL) {
        self.store = store
        self.root = root
    }

    package func requirement(
        manifest: LocalModelRevisionManifest,
        completedArtifactBytes: UInt64
    ) throws -> LocalStorageRequirement {
        let artifactBytes = try manifest.artifacts.reduce(UInt64(0)) { total, artifact in
            try adding(total, artifact.byteSize)
        }
        guard completedArtifactBytes <= artifactBytes else {
            throw diskFailure("download.progress_invalid", "completed artifact bytes exceed signed size")
        }
        let reserve = max(512 * 1_024 * 1_024, manifest.installedByteSize / 10)
        let requirement = LocalStorageRequirement(
            remainingDownloadBytes: artifactBytes - completedArtifactBytes,
            verificationOverheadBytes: manifest.installedByteSize,
            safetyReserveBytes: reserve
        )
        _ = try adding(
            try adding(requirement.remainingDownloadBytes, requirement.verificationOverheadBytes),
            requirement.safetyReserveBytes
        )
        return requirement
    }

    package func preflight(
        installationID: String,
        manifest: LocalModelRevisionManifest,
        completedArtifactBytes: UInt64,
        volume: any LocalVolumeCapacity
    ) async throws -> LocalDiskReservation {
        let requirement = try requirement(
            manifest: manifest,
            completedArtifactBytes: completedArtifactBytes
        )
        let required = try adding(
            try adding(requirement.remainingDownloadBytes, requirement.verificationOverheadBytes),
            requirement.safetyReserveBytes
        )
        let available = try volume.availableImportantUsageBytes(at: root)
        let reservationID = "reservation-\(UUID().uuidString.lowercased())"
        let stored = try store.reserveDiskCapacity(
            reservationID: reservationID,
            installationID: installationID,
            requiredBytes: required,
            availableBytes: available
        )
        return LocalDiskReservation(
            reservationID: stored.reservationID,
            installationID: stored.installationID,
            reservedBytes: stored.reservedBytes
        )
    }
}

private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
        throw diskFailure("download.size_overflow", "local storage requirement exceeds UInt64")
    }
    return sum
}

private func diskFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
