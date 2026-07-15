import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Security

public struct PreparedLocalSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let targetID: LLMTargetID
    public let targetRevision: UInt64
    public let binding: HostBindingTuple
    public let requirementsHash: String
    public let installationID: String
    public let installationStateRevision: UInt64
    public let modelRevision: LocalModelRevisionID
    public let catalogRevision: UInt64
    public let capabilitySnapshot: CapabilitySnapshot
    public let capabilitySnapshotDigest: String
    public let resolvedConfiguration: GenerationConfiguration
    public let resolvedParametersDigest: String
    public let template: LocalChatTemplateSelector
    public let toolCallCodecID: String?
    public let hostProcessEpoch: HostProcessEpoch
    public let loadedModelLeaseID: String
    public let activeSessionLeaseID: String

    public init(
        sessionID: String,
        targetID: LLMTargetID,
        targetRevision: UInt64,
        binding: HostBindingTuple,
        requirementsHash: String,
        installationID: String,
        installationStateRevision: UInt64,
        modelRevision: LocalModelRevisionID,
        catalogRevision: UInt64,
        capabilitySnapshot: CapabilitySnapshot,
        capabilitySnapshotDigest: String,
        resolvedConfiguration: GenerationConfiguration,
        resolvedParametersDigest: String,
        template: LocalChatTemplateSelector,
        toolCallCodecID: String?,
        hostProcessEpoch: HostProcessEpoch,
        loadedModelLeaseID: String,
        activeSessionLeaseID: String
    ) {
        self.sessionID = sessionID
        self.targetID = targetID
        self.targetRevision = targetRevision
        self.binding = binding
        self.requirementsHash = requirementsHash
        self.installationID = installationID
        self.installationStateRevision = installationStateRevision
        self.modelRevision = modelRevision
        self.catalogRevision = catalogRevision
        self.capabilitySnapshot = capabilitySnapshot
        self.capabilitySnapshotDigest = capabilitySnapshotDigest
        self.resolvedConfiguration = resolvedConfiguration
        self.resolvedParametersDigest = resolvedParametersDigest
        self.template = template
        self.toolCallCodecID = toolCallCodecID
        self.hostProcessEpoch = hostProcessEpoch
        self.loadedModelLeaseID = loadedModelLeaseID
        self.activeSessionLeaseID = activeSessionLeaseID
    }

    package static func generateSessionID() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw LLMFailure(
                code: "local_engine.random_generation_failed",
                message: "could not generate a local session identity",
                retryable: true
            )
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

package enum PreparedLocalSessionState: String, Equatable, Sendable {
    case prepared
    case awaitingToolResult = "awaiting_tool_result"
    case terminal
    case quarantined
    case closed
}

package struct StoredPreparedLocalSession: Equatable, Sendable {
    package let session: PreparedLocalSession
    package let state: PreparedLocalSessionState
}
