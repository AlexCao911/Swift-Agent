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

public typealias LLMBackendEventStream = AsyncThrowingStream<LLMBackendEvent, Error>

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

    public static func validated(
        outcome: LLMGenerationOutcome,
        orderedCallIDs: [String],
        finishReason: LLMFinishReason
    ) throws -> Self {
        let unique = Set(orderedCallIDs)
        switch outcome {
        case .finalResponse:
            guard orderedCallIDs.isEmpty, finishReason != .toolCalls else {
                throw LLMBackendCompletionValidationError()
            }
        case .toolCallsReady:
            guard !orderedCallIDs.isEmpty,
                  unique.count == orderedCallIDs.count,
                  orderedCallIDs.allSatisfy({ !$0.isEmpty }),
                  finishReason == .toolCalls
            else { throw LLMBackendCompletionValidationError() }
        }
        return Self(outcome: outcome, orderedCallIDs: orderedCallIDs, finishReason: finishReason)
    }
}

public struct LLMBackendOperationStart: Equatable, Sendable {
    public let commandID: String
    public let opaqueOperationID: String
    public init(commandID: String, opaqueOperationID: String) {
        self.commandID = commandID; self.opaqueOperationID = opaqueOperationID
    }
}

public enum LLMBackendFailureCode: String, Equatable, Sendable {
    case notReady = "not_ready", unsupportedCapability = "unsupported_capability"
    case contextExceeded = "context_exceeded", egressDenied = "egress_denied"
    case rateLimited = "rate_limited", generationFailed = "generation_failed"
    case streamInterrupted = "stream_interrupted", cancelled
}

public struct LLMBackendFailure: Equatable, Sendable {
    public let code: LLMBackendFailureCode
    public init(code: LLMBackendFailureCode) { self.code = code }
}

public enum LLMBackendSessionCloseDisposition: String, Equatable, Sendable {
    case closed, alreadyClosed = "already_closed"
}

public struct LLMBackendCompletionValidationError: Error, Equatable, Sendable {
    public let code = "llm.completion.invalid"
    public init() {}
}

public enum LLMBackendEvent: Equatable, Sendable {
    case generationStarted(LLMBackendOperationStart)
    case textDelta(String)
    case reasoningSummaryDelta(String)
    case toolCallStarted(callID: String, name: String)
    case toolCallArgumentsDelta(callID: String, delta: String)
    case toolCallCompleted(NormalizedToolCall)
    case usageUpdated(LLMUsage)
    case generationCompleted(LLMBackendCompletion)
    case failed(LLMBackendFailure)
    case cancelled
    case sessionClosed(commandID: String, disposition: LLMBackendSessionCloseDisposition)
}
