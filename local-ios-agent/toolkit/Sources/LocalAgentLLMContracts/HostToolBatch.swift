public struct HostToolCall: Codable, Equatable, Sendable {
    public let callID: String
    public let toolName: String
    public let argumentsJSON: String

    public init(callID: String, toolName: String, argumentsJSON: String) {
        self.callID = callID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case toolName = "tool_name"
        case argumentsJSON = "arguments_json"
    }
}

public struct HostToolBatch: Codable, Equatable, Sendable {
    public let batchID: String
    public let runID: String
    public let orderedCalls: [HostToolCall]

    public init(batchID: String, runID: String, orderedCalls: [HostToolCall]) {
        self.batchID = batchID
        self.runID = runID
        self.orderedCalls = orderedCalls
    }

    private enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case runID = "run_id"
        case orderedCalls = "ordered_calls"
    }
}

public struct HostToolBatchCompletion: Codable, Equatable, Sendable {
    public let batchID: String
    public let runID: String
    public let orderedResults: [HostToolResult]

    public init(batchID: String, runID: String, orderedResults: [HostToolResult]) {
        self.batchID = batchID
        self.runID = runID
        self.orderedResults = orderedResults
    }

    private enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case runID = "run_id"
        case orderedResults = "ordered_results"
    }
}
