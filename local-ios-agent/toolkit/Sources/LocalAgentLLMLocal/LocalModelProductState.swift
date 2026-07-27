import Foundation

public enum LocalModelRepairAction: String, Equatable, Sendable {
    case none
    case resume
    case retry
    case cancel
    case delete
}

public struct LocalModelProductState: Equatable, Identifiable, Sendable {
    public let installationID: String
    public let modelRevision: LocalModelRevisionID
    public let state: LocalInstallationState
    public let receivedBytes: UInt64
    public let expectedBytes: UInt64
    public let installedBytes: UInt64
    public let requiredBytes: UInt64
    public let repairAction: LocalModelRepairAction

    public init(
        installationID: String,
        modelRevision: LocalModelRevisionID,
        state: LocalInstallationState,
        receivedBytes: UInt64,
        expectedBytes: UInt64,
        installedBytes: UInt64,
        requiredBytes: UInt64,
        repairAction: LocalModelRepairAction
    ) {
        self.installationID = installationID
        self.modelRevision = modelRevision
        self.state = state
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.installedBytes = installedBytes
        self.requiredBytes = requiredBytes
        self.repairAction = repairAction
    }

    public var id: String { installationID }
}

public struct LocalDiskProductState: Equatable, Sendable {
    public let availableImportantUsageBytes: UInt64
    public let reservedBytes: UInt64
    public let installedBytes: UInt64

    public init(
        availableImportantUsageBytes: UInt64,
        reservedBytes: UInt64,
        installedBytes: UInt64
    ) {
        self.availableImportantUsageBytes = availableImportantUsageBytes
        self.reservedBytes = reservedBytes
        self.installedBytes = installedBytes
    }
}
