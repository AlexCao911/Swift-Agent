import Foundation
import LocalAgentLLMContracts

public enum ProviderValidationStatus: Equatable, Sendable {
    case unvalidated
    case current(expiresAt: Date)
    case stale
    case invalidated(reasonCode: String)

    public var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }
}

public struct CloudProviderProductState: Equatable, Identifiable, Sendable {
    public let profileID: String
    public let revision: UInt64
    public let presetID: ProviderPresetID
    public let displayName: String
    public let displayOrigin: String
    public let retentionMode: ProviderRetentionMode
    public let validation: ProviderValidationStatus

    public var id: String { "\(profileID):\(revision)" }
}

public struct CloudModelProductState: Equatable, Identifiable, Sendable {
    public let profileID: String
    public let profileRevision: UInt64
    public let modelID: String
    public let modelRevision: String?
    public let capabilities: CapabilitySnapshot
    public let parameterSchema: LLMParameterSchema
    public let validation: ProviderValidationStatus

    public var id: String {
        "\(profileID):\(profileRevision):\(modelID)"
    }
}
