import LocalAgentLLMContracts

public enum LLMTargetKind: String, Codable, Equatable, Sendable {
    case local
    case cloud
}

public struct LLMTargetReference: Codable, Equatable, Sendable {
    public let targetID: String
    public let revision: UInt64

    public init(targetID: String, revision: UInt64) {
        self.targetID = targetID
        self.revision = revision
    }
}

public struct LLMTargetRevision: Codable, Equatable, Sendable {
    public let targetID: String
    public let revision: UInt64
    public let kind: LLMTargetKind
    public let modelID: String
    public let defaultParameters: GenerationConfiguration

    public init(
        targetID: String,
        revision: UInt64,
        kind: LLMTargetKind,
        modelID: String,
        defaultParameters: GenerationConfiguration
    ) {
        self.targetID = targetID
        self.revision = revision
        self.kind = kind
        self.modelID = modelID
        self.defaultParameters = defaultParameters
    }

    public var reference: LLMTargetReference {
        LLMTargetReference(targetID: targetID, revision: revision)
    }
}
