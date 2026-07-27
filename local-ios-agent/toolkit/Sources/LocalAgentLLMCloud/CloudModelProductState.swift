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
    public let baseURL: URL
    public let retentionMode: ProviderRetentionMode
    public let validation: ProviderValidationStatus
    public let hasStoredCredential: Bool

    public init(
        profileID: String,
        revision: UInt64,
        presetID: ProviderPresetID,
        displayName: String,
        displayOrigin: String,
        baseURL: URL,
        retentionMode: ProviderRetentionMode,
        validation: ProviderValidationStatus,
        hasStoredCredential: Bool
    ) {
        self.profileID = profileID
        self.revision = revision
        self.presetID = presetID
        self.displayName = displayName
        self.displayOrigin = displayOrigin
        self.baseURL = baseURL
        self.retentionMode = retentionMode
        self.validation = validation
        self.hasStoredCredential = hasStoredCredential
    }

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

    public init(
        profileID: String,
        profileRevision: UInt64,
        modelID: String,
        modelRevision: String?,
        capabilities: CapabilitySnapshot,
        parameterSchema: LLMParameterSchema,
        validation: ProviderValidationStatus
    ) {
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.capabilities = capabilities
        self.parameterSchema = parameterSchema
        self.validation = validation
    }

    public var id: String {
        "\(profileID):\(profileRevision):\(modelID)"
    }
}
