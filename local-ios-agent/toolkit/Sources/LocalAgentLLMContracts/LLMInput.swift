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

public struct HostModelMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: CanonicalJSONValue

    public init(role: String, content: CanonicalJSONValue) {
        self.role = role
        self.content = content
    }
}

public struct HostAttachmentReference: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let displayName: String
    public let mediaType: String
    public let modality: String
    public let contentDigest: String

    public init(
        attachmentID: String,
        displayName: String,
        mediaType: String,
        modality: String,
        contentDigest: String
    ) {
        self.attachmentID = attachmentID
        self.displayName = displayName
        self.mediaType = mediaType
        self.modality = modality
        self.contentDigest = contentDigest
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case displayName = "display_name"
        case mediaType = "media_type"
        case modality
        case contentDigest = "content_digest"
    }
}

public struct HostToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: CanonicalJSONValue

    public init(
        name: String,
        description: String,
        inputSchema: CanonicalJSONValue
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

public struct HostModelRequest: Codable, Equatable, Sendable {
    public let runID: String
    public let conversationStreamID: String
    public let systemPrompt: String
    public let orderedMessages: [HostModelMessage]
    public let attachmentReferences: [HostAttachmentReference]
    public let orderedToolDefinitions: [HostToolDefinition]

    public init(
        runID: String,
        conversationStreamID: String,
        systemPrompt: String,
        orderedMessages: [HostModelMessage],
        attachmentReferences: [HostAttachmentReference],
        orderedToolDefinitions: [HostToolDefinition]
    ) {
        self.runID = runID
        self.conversationStreamID = conversationStreamID
        self.systemPrompt = systemPrompt
        self.orderedMessages = orderedMessages
        self.attachmentReferences = attachmentReferences
        self.orderedToolDefinitions = orderedToolDefinitions
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case conversationStreamID = "conversation_stream_id"
        case systemPrompt = "system_prompt"
        case orderedMessages = "ordered_messages"
        case attachmentReferences = "attachment_references"
        case orderedToolDefinitions = "ordered_tool_definitions"
    }
}

public enum HostModelEvent: Codable, Equatable, Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(
        callID: String,
        toolName: String,
        argumentsFragment: String
    )
    case usage(CanonicalJSONValue)

    private enum Kind: String, Codable {
        case textDelta = "text_delta"
        case reasoningDelta = "reasoning_delta"
        case toolCallDelta = "tool_call_delta"
        case usage
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text
        case callID = "call_id"
        case toolName = "tool_name"
        case argumentsFragment = "arguments_fragment"
        case usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .textDelta:
            self = .textDelta(try container.decode(String.self, forKey: .text))
        case .reasoningDelta:
            self = .reasoningDelta(try container.decode(String.self, forKey: .text))
        case .toolCallDelta:
            self = .toolCallDelta(
                callID: try container.decode(String.self, forKey: .callID),
                toolName: try container.decode(String.self, forKey: .toolName),
                argumentsFragment: try container.decode(
                    String.self,
                    forKey: .argumentsFragment
                )
            )
        case .usage:
            self = .usage(
                try container.decode(CanonicalJSONValue.self, forKey: .usage)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .textDelta(text):
            try container.encode(Kind.textDelta, forKey: .kind)
            try container.encode(text, forKey: .text)
        case let .reasoningDelta(text):
            try container.encode(Kind.reasoningDelta, forKey: .kind)
            try container.encode(text, forKey: .text)
        case let .toolCallDelta(callID, toolName, argumentsFragment):
            try container.encode(Kind.toolCallDelta, forKey: .kind)
            try container.encode(callID, forKey: .callID)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(argumentsFragment, forKey: .argumentsFragment)
        case let .usage(usage):
            try container.encode(Kind.usage, forKey: .kind)
            try container.encode(usage, forKey: .usage)
        }
    }
}
