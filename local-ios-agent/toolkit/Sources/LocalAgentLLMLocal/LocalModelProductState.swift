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

    public var id: String { installationID }
}

public struct LocalDiskProductState: Equatable, Sendable {
    public let availableImportantUsageBytes: UInt64
    public let reservedBytes: UInt64
    public let installedBytes: UInt64
}
