public struct NormalizedToolCall: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let argumentsJSON: String

    public init(callID: String, name: String, argumentsJSON: String) {
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct LLMUsage: Equatable, Sendable {
    public let inputTokens: UInt64?
    public let outputTokens: UInt64?

    public init(inputTokens: UInt64?, outputTokens: UInt64?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum LLMFinishReason: String, Equatable, Sendable {
    case stop
    case toolCalls = "tool_calls"
    case length
    case contentFiltered = "content_filtered"
    case other
}

public enum LLMGenerationOutcome: String, Equatable, Sendable {
    case finalResponse = "final_response"
    case toolCallsReady = "tool_calls_ready"
}

public struct LLMBackendCompletion: Equatable, Sendable {
    public let outcome: LLMGenerationOutcome
    public let orderedCallIDs: [String]
    public let finishReason: LLMFinishReason

    public init(
        outcome: LLMGenerationOutcome,
        orderedCallIDs: [String],
        finishReason: LLMFinishReason
    ) {
        self.outcome = outcome
        self.orderedCallIDs = orderedCallIDs
        self.finishReason = finishReason
    }
}

public enum LLMBackendEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCallStarted(callID: String, name: String)
    case toolCallArgumentsDelta(callID: String, delta: String)
    case toolCallCompleted(NormalizedToolCall)
    case usageUpdated(LLMUsage)
    case generationCompleted(LLMBackendCompletion)
    case cancelled
}
