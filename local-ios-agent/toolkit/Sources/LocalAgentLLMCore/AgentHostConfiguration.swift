import LocalAgentLLMContracts

public struct AgentHostConfiguration: Codable, Equatable, Sendable {
    public let bindingID: String
    public let revision: UInt64
    public let agentProfileID: String
    public let agentProfileRevision: UInt64
    public let llmSlotID: String
    public let requirementsHash: String
    public let llmTargetID: String
    public let llmTargetRevision: UInt64
    public let parameterOverrides: GenerationConfiguration

    public init(
        bindingID: String,
        revision: UInt64,
        agentProfileID: String,
        agentProfileRevision: UInt64,
        llmSlotID: String,
        requirementsHash: String,
        llmTargetID: String,
        llmTargetRevision: UInt64,
        parameterOverrides: GenerationConfiguration
    ) {
        self.bindingID = bindingID
        self.revision = revision
        self.agentProfileID = agentProfileID
        self.agentProfileRevision = agentProfileRevision
        self.llmSlotID = llmSlotID
        self.requirementsHash = requirementsHash
        self.llmTargetID = llmTargetID
        self.llmTargetRevision = llmTargetRevision
        self.parameterOverrides = parameterOverrides
    }

    public var selectedTarget: LLMTargetReference {
        LLMTargetReference(targetID: llmTargetID, revision: llmTargetRevision)
    }
}
