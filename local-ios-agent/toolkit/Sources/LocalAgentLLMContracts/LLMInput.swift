public enum LLMInputRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum LLMInputModality: String, Codable, Equatable, Sendable {
    case image
    case audio
    case video
    case document
}

public enum LLMInputContent: Codable, Equatable, Sendable {
    case text(String)
    case attachment(
        modality: LLMInputModality,
        attachmentID: String,
        mediaType: String
    )
}

public struct LLMInputMessage: Codable, Equatable, Sendable {
    public let role: LLMInputRole
    public let content: [LLMInputContent]

    public init(role: LLMInputRole, content: [LLMInputContent]) {
        self.role = role
        self.content = content
    }
}

public struct AgentLLMInput: Codable, Equatable, Sendable {
    public let inputID: String
    public let messages: [LLMInputMessage]

    public init(inputID: String, messages: [LLMInputMessage]) {
        self.inputID = inputID
        self.messages = messages
    }
}
