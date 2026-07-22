import Foundation
import LocalAgentLLMContracts

package enum ChatProviderSemantics: Sendable {
    case deepSeek
    case glm

    var adapterID: String {
        switch self {
        case .deepSeek: "deepseek.chat_completions"
        case .glm: "glm.chat_completions"
        }
    }
}

private struct ChatToolContinuation: Sendable {
    let index: Int
    let callID: String
    let name: String
    let arguments: String

    var wireObject: [String: Any] {
        [
            "index": index,
            "id": callID,
            "type": "function",
            "function": ["name": name, "arguments": arguments],
        ]
    }
}

private struct ChatAssistantContinuation: Sendable {
    let reasoningContent: String
    let content: String
    let tools: [ChatToolContinuation]

    func wireObject(preserveReasoning: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "role": "assistant",
            "content": content,
            "tool_calls": tools.map(\.wireObject),
        ]
        if preserveReasoning, !reasoningContent.isEmpty {
            object["reasoning_content"] = reasoningContent
        }
        return object
    }
}

package final class OpenAIChatCompletionsSession: CloudProviderSession, @unchecked Sendable {
    private let lock = NSLock()
    private let context: CloudProviderSessionContext
    private let semantics: ChatProviderSemantics
    private var assistantContinuation: ChatAssistantContinuation?
    private var thinkingEnabled = false
    private var decodeTask: Task<Void, Never>?
    private var closed = false

    package init(
        context: CloudProviderSessionContext,
        semantics: ChatProviderSemantics
    ) throws {
        guard context.retentionMode == .statelessRequired,
              context.retentionApprovalRevision == nil,
              context.retentionApprovalDigest == nil,
              !context.targetID.rawValue.isEmpty,
              context.targetRevision > 0,
              !context.providerProfileID.isEmpty,
              context.providerProfileRevision > 0,
              !context.modelID.isEmpty
        else {
            throw chatFailure(
                "cloud_adapter.retention_unsupported",
                "Chat adapter requires an exact stateless provider profile"
            )
        }
        self.context = context
        self.semantics = semantics
    }

    package func encodeStart(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        try encode(turn)
    }

    package func encodeResume(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        try encode(turn)
    }

    package func decode(
        _ events: AsyncThrowingStream<SSEEvent, Error>
    ) -> LLMBackendEventStream {
        let pair = LLMBackendEventStream.makeStream(bufferingPolicy: .bufferingOldest(32))
        lock.lock()
        guard !closed, decodeTask == nil else {
            lock.unlock()
            pair.continuation.finish(throwing: chatFailure(
                "cloud_adapter.session_busy",
                "Chat session already has an active generation"
            ))
            return pair.stream
        }
        let preserveReasoning = semantics == .deepSeek || thinkingEnabled
        let task = Task { [weak self] in
            guard let self else {
                pair.continuation.finish(throwing: chatFailure(
                    "cloud_adapter.session_closed",
                    "Chat session was released"
                ))
                return
            }
            var decoder = OpenAIChatCompletionsDecoder(
                providerSemanticID: self.semantics.adapterID,
                preserveReasoning: preserveReasoning
            )
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    for output in try decoder.consume(event) {
                        try yieldChat(output, to: pair.continuation)
                    }
                }
                try decoder.finish()
                self.record(assistant: decoder.assistantContinuation)
                pair.continuation.finish()
            } catch is CancellationError {
                _ = pair.continuation.yield(.cancelled)
                pair.continuation.finish()
            } catch let failure as LLMFailure {
                pair.continuation.finish(throwing: failure)
            } catch {
                pair.continuation.finish(throwing: chatFailure(
                    "cloud_adapter.stream_invalid",
                    "Chat completion stream could not be decoded"
                ))
            }
            self.clearDecodeTask()
        }
        decodeTask = task
        lock.unlock()
        pair.continuation.onTermination = { @Sendable _ in task.cancel() }
        return pair.stream
    }

    package func cancel() async {
        lock.withLock { decodeTask }?.cancel()
    }

    package func close() async {
        let task = lock.withLock {
            closed = true
            let task = decodeTask
            decodeTask = nil
            assistantContinuation = nil
            return task
        }
        task?.cancel()
    }

    private func encode(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        let snapshot = lock.withLock {
            (closed, assistantContinuation)
        }
        guard !snapshot.0 else {
            throw chatFailure("cloud_adapter.session_closed", "Chat session is closed")
        }
        try validate(turn)
        try validateModel()

        var body: [String: Any] = [
            "model": context.modelID,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        let enabled = try applyChatParameters(
            turn.validated.semantic.resolvedParameters,
            semantics: semantics,
            modelID: context.modelID,
            body: &body
        )
        lock.withLock { thinkingEnabled = enabled }

        var messages = try chatHistory(
            turn.validated.semantic.providerRequiredSemanticHistory
        )
        messages.append(contentsOf: try chatMessages(turn.validated.semantic.input))
        let toolResults = turn.validated.semantic.toolResults
        if !toolResults.isEmpty {
            guard let assistant = snapshot.1 else {
                throw chatFailure(
                    "cloud_adapter.continuation_missing",
                    "tool results require the complete preceding assistant tool-call message"
                )
            }
            let expected = Set(assistant.tools.map(\.callID))
            let supplied = Set(toolResults.map(\.callID))
            guard expected == supplied, supplied.count == toolResults.count else {
                throw chatFailure(
                    "cloud_adapter.tool_result_batch_mismatch",
                    "tool-result batch does not match the preceding ordered tool calls"
                )
            }
            messages.append(assistant.wireObject(
                preserveReasoning: semantics == .deepSeek || enabled
            ))
            messages.append(contentsOf: try chatToolResultMessages(toolResults))
        }
        body["messages"] = messages
        let tools = try chatTools(turn.validated.semantic.canonicalToolSchema)
        if !tools.isEmpty { body["tools"] = tools }

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw chatFailure("cloud_adapter.request_invalid", "Chat request could not be encoded")
        }
        return try CloudWireRequest(
            method: "POST",
            path: "/chat/completions",
            queryItems: [],
            headers: [
                "accept": "text/event-stream",
                "content-type": "application/json",
            ],
            body: data,
            dataProvenance: .generation
        )
    }

    private func validate(_ turn: AuthorizedCloudGenerationTurn) throws {
        guard turn.targetID == context.targetID,
              turn.targetRevision == context.targetRevision,
              turn.profileID == context.providerProfileID,
              turn.profileRevision == context.providerProfileRevision,
              turn.retentionMode == .statelessRequired,
              turn.retentionApprovalRevision == nil,
              turn.retentionApprovalDigest == nil
        else {
            throw chatFailure(
                "cloud_adapter.session_mismatch",
                "authorized turn does not match the exact Chat session"
            )
        }
        guard turn.validated.semantic.resolvedAttachments.isEmpty,
              turn.validated.semantic.input.messages.allSatisfy({ message in
                  message.content.allSatisfy { if case .text = $0 { true } else { false } }
              })
        else {
            throw chatFailure(
                "capability.cloud_attachment_path_unavailable",
                "cloud attachment byte transport is unavailable in Phase 3"
            )
        }
    }

    private func validateModel() throws {
        let model = context.modelID.lowercased()
        let valid = semantics == .deepSeek
            ? model.hasPrefix("deepseek-")
            : model.hasPrefix("glm-")
        guard valid else {
            throw chatFailure(
                "cloud_adapter.model_incompatible",
                "model does not belong to this Chat semantic adapter"
            )
        }
    }

    private func record(assistant: ChatAssistantContinuation?) {
        lock.withLock {
            if !closed { assistantContinuation = assistant }
        }
    }

    private func clearDecodeTask() {
        lock.withLock { decodeTask = nil }
    }
}

private struct OpenAIChatCompletionsDecoder {
    private struct PartialTool {
        let index: Int
        var callID: String
        var name: String
        var arguments: String
        var started: Bool
    }

    let providerSemanticID: String
    let preserveReasoning: Bool
    private(set) var assistantContinuation: ChatAssistantContinuation?
    private var reasoning = ""
    private var content = ""
    private var tools: [Int: PartialTool] = [:]
    private var finishReason: LLMFinishReason?
    private var done = false

    init(providerSemanticID: String, preserveReasoning: Bool) {
        self.providerSemanticID = providerSemanticID
        self.preserveReasoning = preserveReasoning
    }

    mutating func consume(_ event: SSEEvent) throws -> [LLMBackendEvent] {
        guard !done else {
            throw chatFailure(
                "cloud_adapter.terminal_duplicate",
                "Chat stream emitted data after [DONE]"
            )
        }
        if event.data == Data("[DONE]".utf8) {
            guard let finishReason else {
                throw chatFailure("stream.interrupted", "Chat stream ended before finish_reason")
            }
            done = true
            let ordered = try terminalTools(for: finishReason)
            if finishReason == .toolCalls {
                assistantContinuation = ChatAssistantContinuation(
                    reasoningContent: preserveReasoning ? reasoning : "",
                    content: content,
                    tools: ordered.map {
                        ChatToolContinuation(
                            index: $0.index,
                            callID: $0.callID,
                            name: $0.name,
                            arguments: $0.arguments
                        )
                    }
                )
            }
            let callIDs = ordered.map(\.callID)
            return [.generationCompleted(LLMBackendCompletion(
                outcome: finishReason == .toolCalls ? .toolCallsReady : .finalResponse,
                orderedCallIDs: finishReason == .toolCalls ? callIDs : [],
                finishReason: finishReason
            ))]
        }
        let object = try chatObject(event.data)
        if let error = object["error"] as? [String: Any] {
            throw chatProviderError(error, providerSemanticID: providerSemanticID)
        }
        var output: [LLMBackendEvent] = []
        if let choices = object["choices"] as? [[String: Any]], !choices.isEmpty {
            guard choices.count == 1, let choice = choices.first else {
                throw chatFailure("cloud_adapter.event_invalid", "Chat stream choice count is invalid")
            }
            if let delta = choice["delta"] as? [String: Any] {
                if let reasoningDelta = delta["reasoning_content"] as? String {
                    reasoning += reasoningDelta
                }
                if let text = delta["content"] as? String, !text.isEmpty {
                    content += text
                    output.append(.textDelta(text))
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    output.append(contentsOf: try consumeToolDeltas(calls))
                }
            }
            if let rawFinish = choice["finish_reason"] as? String {
                guard finishReason == nil else {
                    throw chatFailure(
                        "cloud_adapter.terminal_duplicate",
                        "Chat stream emitted finish_reason more than once"
                    )
                }
                finishReason = mapFinishReason(rawFinish)
                if finishReason == .toolCalls {
                    output.append(contentsOf: try completeTools())
                } else if !tools.isEmpty {
                    throw chatFailure(
                        "cloud_adapter.terminal_conflict",
                        "Chat stream accumulated tool calls but ended as a final response"
                    )
                }
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            output.append(.usageUpdated(LLMUsage(
                inputTokens: chatUnsigned(usage["prompt_tokens"]),
                outputTokens: chatUnsigned(usage["completion_tokens"])
            )))
        }
        return output
    }

    func finish() throws {
        guard done else {
            throw chatFailure(
                "stream.interrupted",
                "Chat SSE ended before finish_reason plus [DONE]"
            )
        }
    }

    private mutating func consumeToolDeltas(
        _ deltas: [[String: Any]]
    ) throws -> [LLMBackendEvent] {
        var output: [LLMBackendEvent] = []
        for delta in deltas {
            guard let index = (delta["index"] as? NSNumber)?.intValue ?? delta["index"] as? Int,
                  index >= 0
            else { throw chatFailure("cloud_adapter.tool_call_invalid", "tool index is invalid") }
            let function = delta["function"] as? [String: Any]
            let incomingID = delta["id"] as? String
            let incomingName = function?["name"] as? String
            let arguments = function?["arguments"] as? String ?? ""
            if var current = tools[index] {
                if let incomingID, incomingID != current.callID {
                    throw chatFailure("cloud_adapter.tool_call_invalid", "tool call ID changed")
                }
                if let incomingName, incomingName != current.name {
                    throw chatFailure("cloud_adapter.tool_call_invalid", "tool name changed")
                }
                current.arguments += arguments
                tools[index] = current
                if !arguments.isEmpty {
                    output.append(.toolCallArgumentsDelta(callID: current.callID, delta: arguments))
                }
            } else {
                guard let incomingID, !incomingID.isEmpty,
                      let incomingName, !incomingName.isEmpty,
                      index == tools.count
                else {
                    throw chatFailure(
                        "cloud_adapter.tool_call_invalid",
                        "new indexed tool call lacks a stable identity"
                    )
                }
                tools[index] = PartialTool(
                    index: index,
                    callID: incomingID,
                    name: incomingName,
                    arguments: arguments,
                    started: true
                )
                output.append(.toolCallStarted(callID: incomingID, name: incomingName))
                if !arguments.isEmpty {
                    output.append(.toolCallArgumentsDelta(callID: incomingID, delta: arguments))
                }
            }
        }
        return output
    }

    private mutating func completeTools() throws -> [LLMBackendEvent] {
        try completeToolValues().map { tool in
            .toolCallCompleted(NormalizedToolCall(
                callID: tool.callID,
                name: tool.name,
                argumentsJSON: tool.arguments
            ))
        }
    }

    private func terminalTools(
        for finishReason: LLMFinishReason
    ) throws -> [PartialTool] {
        guard finishReason == .toolCalls else {
            guard tools.isEmpty else {
                throw chatFailure(
                    "cloud_adapter.terminal_conflict",
                    "Chat stream accumulated tool calls but ended as a final response"
                )
            }
            return []
        }
        return try completeToolValues()
    }

    private func completeToolValues() throws -> [PartialTool] {
        let ordered = tools.keys.sorted().compactMap { tools[$0] }
        guard !ordered.isEmpty, ordered.indices.allSatisfy({ ordered[$0].index == $0 }) else {
            throw chatFailure("cloud_adapter.tool_call_incomplete", "tool call batch is incomplete")
        }
        for tool in ordered {
            guard let data = tool.arguments.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(
                      with: data,
                      options: [.fragmentsAllowed]
                  )) != nil
            else {
                throw chatFailure(
                    "cloud_adapter.tool_call_incomplete",
                    "tool call ended before one complete JSON argument value"
                )
            }
        }
        return ordered
    }
}

private func chatObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= 1_024 * 1_024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw chatFailure("cloud_adapter.event_invalid", "Chat event JSON is invalid") }
    return object
}

private func mapFinishReason(_ value: String) -> LLMFinishReason {
    switch value {
    case "stop": .stop
    case "tool_calls", "function_call": .toolCalls
    case "length": .length
    case "content_filter": .contentFiltered
    default: .other
    }
}

private func chatProviderError(
    _ error: [String: Any],
    providerSemanticID: String
) -> LLMFailure {
    let code = (error["code"] as? String ?? "").lowercased()
    let diagnostics = ["provider_semantic_id": providerSemanticID]
    if code.contains("api_key") || code.contains("auth") {
        return chatFailure(
            "cloud_transport.unauthorized",
            "provider rejected the credential",
            redactedDiagnostics: diagnostics
        )
    }
    if code.contains("rate") || code.contains("quota") {
        return chatFailure(
            "cloud_transport.rate_limited",
            "provider rate limit was reached",
            retryable: true,
            recoveryAction: .retry,
            redactedDiagnostics: diagnostics
        )
    }
    return chatFailure(
        "cloud_adapter.provider_stream_error",
        "provider emitted a Chat streaming error",
        redactedDiagnostics: diagnostics
    )
}

private func chatHistory(_ value: CanonicalJSONValue) throws -> [[String: Any]] {
    let object = try chatFoundationObject(value)
    guard let array = object as? [[String: Any]] else {
        if object is NSNull { return [] }
        if let values = object as? [Any], values.isEmpty { return [] }
        throw chatFailure(
            "cloud_adapter.semantic_history_invalid",
            "Chat semantic history must contain complete message objects"
        )
    }
    return array
}

private func chatMessages(_ input: AgentLLMInput) throws -> [[String: Any]] {
    try input.messages.map { message in
        guard message.role != .tool else {
            throw chatFailure(
                "cloud_adapter.message_invalid",
                "tool messages must use normalized tool results"
            )
        }
        var text = ""
        for part in message.content {
            switch part {
            case let .text(value): text += value
            case .attachment:
                throw chatFailure(
                    "capability.cloud_attachment_path_unavailable",
                    "cloud attachment byte transport is unavailable in Phase 3"
                )
            }
        }
        return ["role": message.role.rawValue, "content": text]
    }
}

private func chatToolResultMessages(
    _ results: [NormalizedToolResult]
) throws -> [[String: Any]] {
    try results.map { result in
        let output: String
        if case let .string(value) = result.result {
            output = value
        } else {
            output = String(decoding: try JSONSerialization.data(
                withJSONObject: chatFoundationObject(result.result),
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), as: UTF8.self)
        }
        return [
            "role": "tool",
            "tool_call_id": result.callID,
            "content": output,
        ]
    }
}

private func chatTools(_ schema: CanonicalJSONValue) throws -> [[String: Any]] {
    guard let object = try chatFoundationObject(schema) as? [String: Any],
          let values = object["tools"] as? [Any]
    else { return [] }
    return try values.map { value in
        if let name = value as? String {
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "parameters": ["type": "object", "properties": [:]],
                ],
            ]
        }
        guard let object = value as? [String: Any] else {
            throw chatFailure("cloud_adapter.tool_schema_invalid", "Chat tool schema is invalid")
        }
        return object
    }
}

private func chatFoundationObject(_ value: CanonicalJSONValue) throws -> Any {
    try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    )
}

private func applyChatParameters(
    _ configuration: GenerationConfiguration,
    semantics: ChatProviderSemantics,
    modelID: String,
    body: inout [String: Any]
) throws -> Bool {
    let supported = Set([
        LLMParameterID.samplingTemperature.rawValue,
        LLMParameterID.samplingTopP.rawValue,
        LLMParameterID.generationMaxOutputTokens.rawValue,
        LLMParameterID.generationStopSequences.rawValue,
        LLMParameterID.reasoningEffort.rawValue,
    ])
    guard Set(configuration.parameters.keys).isSubset(of: supported) else {
        throw chatFailure(
            "cloud_adapter.parameter_unsupported",
            "Chat adapter received an unsupported canonical parameter"
        )
    }
    if let value = configuration.value(for: .samplingTemperature) {
        body["temperature"] = try chatDecimal(value, range: 0...2)
    }
    if let value = configuration.value(for: .samplingTopP) {
        body["top_p"] = try chatDecimal(value, range: 0...1)
    }
    if let value = configuration.value(for: .generationMaxOutputTokens) {
        guard case let .integer(number) = value, number > 0 else { throw chatParameterFailure() }
        body["max_tokens"] = number
    }
    if let value = configuration.value(for: .generationStopSequences) {
        guard case let .textList(items) = value,
              !items.isEmpty,
              items.allSatisfy({ !$0.isEmpty })
        else { throw chatParameterFailure() }
        body["stop"] = items
    }
    guard let reasoning = configuration.value(for: .reasoningEffort) else { return false }
    guard case let .text(effort) = reasoning,
          ["none", "minimal", "low", "medium", "high"].contains(effort)
    else { throw chatParameterFailure() }
    let enabled = effort != "none"
    if semantics == .deepSeek, !modelID.lowercased().contains("reasoner") {
        throw chatFailure(
            "cloud_adapter.parameter_unsupported",
            "selected DeepSeek model does not support thinking control"
        )
    }
    body["thinking"] = ["type": enabled ? "enabled" : "disabled"]
    if semantics == .glm { body["clear_thinking"] = !enabled }
    return enabled
}

private func chatDecimal(
    _ value: LLMParameterValue,
    range: ClosedRange<Double>
) throws -> Double {
    guard case let .decimal(number) = value, number.isFinite, range.contains(number) else {
        throw chatParameterFailure()
    }
    return number
}

private func chatParameterFailure() -> LLMFailure {
    chatFailure("cloud_adapter.parameter_invalid", "Chat parameter value is invalid")
}

private func chatUnsigned(_ value: Any?) -> UInt64? {
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    if let value = value as? NSNumber, value.doubleValue >= 0,
       value.doubleValue.rounded() == value.doubleValue {
        return UInt64(value.doubleValue)
    }
    return nil
}

private func yieldChat(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued: return
    case .dropped:
        throw chatFailure(
            "cloud_adapter.consumer_backpressure",
            "Chat consumer exceeded its bounded event buffer"
        )
    case .terminated: throw CancellationError()
    @unknown default:
        throw chatFailure(
            "cloud_adapter.consumer_backpressure",
            "Chat consumer state is unknown"
        )
    }
}

package func chatFailure(
    _ code: String,
    _ message: String,
    retryable: Bool = false,
    recoveryAction: LLMRecoveryAction? = nil,
    redactedDiagnostics: [String: String] = [:]
) -> LLMFailure {
    LLMFailure(
        code: code,
        message: message,
        retryable: retryable,
        recoveryAction: recoveryAction,
        redactedDiagnostics: redactedDiagnostics
    )
}
