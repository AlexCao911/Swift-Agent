import Foundation
import LocalAgentLLMContracts

package enum MessagesProviderSemantics: Sendable {
    case anthropic
    case miniMax

    var adapterID: String {
        switch self {
        case .anthropic: "anthropic.messages"
        case .miniMax: "minimax.messages"
        }
    }
}

private enum MessagesPrivateBlock: Sendable {
    case text(String)
    case thinking(thinking: String, signature: String)
    case toolUse(id: String, name: String, inputJSON: String)

    var wireObject: [String: Any] {
        switch self {
        case let .text(text):
            ["type": "text", "text": text]
        case let .thinking(thinking, signature):
            ["type": "thinking", "thinking": thinking, "signature": signature]
        case let .toolUse(id, name, inputJSON):
            [
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": (try? JSONSerialization.jsonObject(
                    with: Data(inputJSON.utf8),
                    options: [.fragmentsAllowed]
                )) ?? [:],
            ]
        }
    }

    var toolCallID: String? {
        guard case let .toolUse(id, _, _) = self else { return nil }
        return id
    }
}

package final class AnthropicMessagesSession: CloudProviderSession, @unchecked Sendable {
    private let lock = NSLock()
    private let context: CloudProviderSessionContext
    private let semantics: MessagesProviderSemantics
    private var assistantBlocks: [MessagesPrivateBlock]?
    private var summarizedThinking = false
    private var decodeTask: Task<Void, Never>?
    private var closed = false

    package init(
        context: CloudProviderSessionContext,
        semantics: MessagesProviderSemantics
    ) throws {
        guard context.retentionMode == .statelessRequired,
              context.retentionApprovalRevision == nil,
              context.retentionApprovalDigest == nil,
              !context.modelID.isEmpty
        else {
            throw messagesFailure(
                "cloud_adapter.retention_unsupported",
                "Messages adapter requires an exact stateless provider profile"
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
            pair.continuation.finish(throwing: messagesFailure(
                "cloud_adapter.session_busy",
                "Messages session already has an active generation"
            ))
            return pair.stream
        }
        let display = semantics == .anthropic && summarizedThinking
        let task = Task { [weak self] in
            guard let self else {
                pair.continuation.finish(throwing: messagesFailure(
                    "cloud_adapter.session_closed",
                    "Messages session was released"
                ))
                return
            }
            var decoder = AnthropicMessagesDecoder(
                providerSemanticID: self.semantics.adapterID,
                displayThinkingAsSummary: display
            )
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    for output in try decoder.consume(event) {
                        try yieldMessages(output, to: pair.continuation)
                    }
                }
                try decoder.finish()
                self.record(blocks: decoder.assistantBlocks)
                pair.continuation.finish()
            } catch is CancellationError {
                _ = pair.continuation.yield(.cancelled)
                pair.continuation.finish()
            } catch let failure as LLMFailure {
                pair.continuation.finish(throwing: failure)
            } catch {
                pair.continuation.finish(throwing: messagesFailure(
                    "cloud_adapter.stream_invalid",
                    "Messages stream could not be decoded"
                ))
            }
            self.clearDecodeTask()
        }
        decodeTask = task
        lock.unlock()
        pair.continuation.onTermination = { @Sendable _ in task.cancel() }
        return pair.stream
    }

    package func cancel() async { lock.withLock { decodeTask }?.cancel() }

    package func close() async {
        let task = lock.withLock {
            closed = true
            let task = decodeTask
            decodeTask = nil
            assistantBlocks = nil
            return task
        }
        task?.cancel()
    }

    private func encode(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        let state = lock.withLock { (closed, assistantBlocks) }
        guard !state.0 else {
            throw messagesFailure("cloud_adapter.session_closed", "Messages session is closed")
        }
        try validate(turn)
        try validateModel()
        var body: [String: Any] = [
            "model": context.modelID,
            "stream": true,
        ]
        let policy = try applyMessagesParameters(
            turn.validated.semantic.resolvedParameters,
            semantics: semantics,
            body: &body
        )
        lock.withLock { summarizedThinking = policy.summarized }

        let encoded = try messagesInput(turn.validated.semantic.input)
        if !encoded.system.isEmpty { body["system"] = encoded.system }
        var messages = try messagesHistory(
            turn.validated.semantic.providerRequiredSemanticHistory
        )
        messages.append(contentsOf: encoded.messages)
        let results = turn.validated.semantic.toolResults
        if !results.isEmpty {
            guard let blocks = state.1 else {
                throw messagesFailure(
                    "cloud_adapter.continuation_missing",
                    "tool results require the complete preceding assistant block list"
                )
            }
            let expected = blocks.compactMap(\.toolCallID)
            let supplied = results.map(\.callID)
            guard expected == supplied else {
                throw messagesFailure(
                    "cloud_adapter.tool_result_batch_mismatch",
                    "tool-result batch does not match the preceding tool-use blocks"
                )
            }
            messages.append(["role": "assistant", "content": blocks.map(\.wireObject)])
            messages.append(["role": "user", "content": try toolResultBlocks(results)])
        }
        body["messages"] = messages
        let tools = try messagesTools(turn.validated.semantic.canonicalToolSchema)
        if !tools.isEmpty { body["tools"] = tools }

        let data = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try CloudWireRequest(
            method: "POST",
            path: "/messages",
            queryItems: [],
            headers: [
                "accept": "text/event-stream",
                "anthropic-version": "2023-06-01",
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
              turn.validated.semantic.resolvedAttachments.isEmpty
        else {
            throw messagesFailure(
                "cloud_adapter.session_mismatch",
                "authorized turn does not match the exact Messages session"
            )
        }
    }

    private func validateModel() throws {
        let model = context.modelID.lowercased()
        let valid = semantics == .anthropic
            ? model.hasPrefix("claude-")
            : model.hasPrefix("minimax-")
        guard valid else {
            throw messagesFailure(
                "cloud_adapter.model_incompatible",
                "model does not belong to this Messages semantic adapter"
            )
        }
    }

    private func record(blocks: [MessagesPrivateBlock]?) {
        lock.withLock { if !closed { assistantBlocks = blocks } }
    }

    private func clearDecodeTask() { lock.withLock { decodeTask = nil } }
}

private struct AnthropicMessagesDecoder {
    private struct PartialBlock {
        enum Kind { case text, thinking, tool(id: String, name: String) }
        let kind: Kind
        var value: String
        var signature: String
        var stopped: Bool
    }

    let providerSemanticID: String
    let displayThinkingAsSummary: Bool
    private(set) var assistantBlocks: [MessagesPrivateBlock]?
    private var blocks: [PartialBlock] = []
    private var inputTokens: UInt64?
    private var outputTokens: UInt64?
    private var stopReason: String?
    private var terminal = false

    init(providerSemanticID: String, displayThinkingAsSummary: Bool) {
        self.providerSemanticID = providerSemanticID
        self.displayThinkingAsSummary = displayThinkingAsSummary
    }

    mutating func consume(_ event: SSEEvent) throws -> [LLMBackendEvent] {
        guard !terminal else {
            throw messagesFailure(
                "cloud_adapter.terminal_duplicate",
                "Messages stream emitted data after message_stop"
            )
        }
        let known = event.event.map(messagesKnownEvents.contains) ?? true
        if !known { return [] }
        let object = try messagesObject(event.data)
        let type = event.event ?? object["type"] as? String
        switch type {
        case "message_start":
            if let message = object["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                inputTokens = messagesUnsigned(usage["input_tokens"])
            }
            return []
        case "content_block_start":
            return try startBlock(object)
        case "content_block_delta":
            return try deltaBlock(object)
        case "content_block_stop":
            return try stopBlock(object)
        case "message_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let reason = delta["stop_reason"] as? String
            else { throw messagesFailure("cloud_adapter.event_invalid", "stop reason is missing") }
            stopReason = reason
            if let usage = object["usage"] as? [String: Any] {
                outputTokens = messagesUnsigned(usage["output_tokens"])
            }
            return [.usageUpdated(LLMUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens
            ))]
        case "message_stop":
            return try completeMessage()
        case "error":
            throw messagesProviderError(object, providerSemanticID: providerSemanticID)
        case "ping", nil:
            return []
        default:
            return []
        }
    }

    func finish() throws {
        guard terminal else {
            throw messagesFailure("stream.interrupted", "Messages SSE ended before message_stop")
        }
    }

    private mutating func startBlock(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let index = messagesIndex(object["index"]), index == blocks.count,
              let block = object["content_block"] as? [String: Any],
              let type = block["type"] as? String
        else {
            throw messagesFailure("cloud_adapter.block_index_invalid", "content block index is invalid")
        }
        switch type {
        case "text":
            blocks.append(PartialBlock(
                kind: .text,
                value: block["text"] as? String ?? "",
                signature: "",
                stopped: false
            ))
            return []
        case "thinking":
            blocks.append(PartialBlock(
                kind: .thinking,
                value: block["thinking"] as? String ?? "",
                signature: block["signature"] as? String ?? "",
                stopped: false
            ))
            return []
        case "tool_use":
            guard let id = block["id"] as? String, !id.isEmpty,
                  let name = block["name"] as? String, !name.isEmpty
            else { throw messagesFailure("cloud_adapter.tool_call_invalid", "tool block identity is invalid") }
            blocks.append(PartialBlock(
                kind: .tool(id: id, name: name),
                value: "",
                signature: "",
                stopped: false
            ))
            return [.toolCallStarted(callID: id, name: name)]
        default:
            throw messagesFailure("cloud_adapter.block_invalid", "unsupported content block type")
        }
    }

    private mutating func deltaBlock(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let index = messagesIndex(object["index"]), blocks.indices.contains(index),
              !blocks[index].stopped,
              let delta = object["delta"] as? [String: Any],
              let type = delta["type"] as? String
        else { throw messagesFailure("cloud_adapter.block_index_invalid", "content block delta index is invalid") }
        switch (blocks[index].kind, type) {
        case (.text, "text_delta"):
            let value = delta["text"] as? String ?? ""
            blocks[index].value += value
            return value.isEmpty ? [] : [.textDelta(value)]
        case (.thinking, "thinking_delta"):
            let value = delta["thinking"] as? String ?? ""
            blocks[index].value += value
            return displayThinkingAsSummary && !value.isEmpty
                ? [.reasoningSummaryDelta(value)] : []
        case (.thinking, "signature_delta"):
            blocks[index].signature += delta["signature"] as? String ?? ""
            return []
        case let (.tool(id, _), "input_json_delta"):
            let value = delta["partial_json"] as? String ?? ""
            blocks[index].value += value
            return value.isEmpty ? [] : [.toolCallArgumentsDelta(callID: id, delta: value)]
        default:
            throw messagesFailure("cloud_adapter.block_invalid", "content block delta type is invalid")
        }
    }

    private mutating func stopBlock(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let index = messagesIndex(object["index"]), blocks.indices.contains(index),
              !blocks[index].stopped
        else { throw messagesFailure("cloud_adapter.block_index_invalid", "content block stop index is invalid") }
        blocks[index].stopped = true
        guard case let .tool(id, name) = blocks[index].kind else { return [] }
        let json = blocks[index].value
        guard let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else {
            throw messagesFailure(
                "cloud_adapter.tool_arguments_invalid",
                "tool-use input is not one complete JSON value"
            )
        }
        return [.toolCallCompleted(NormalizedToolCall(
            callID: id,
            name: name,
            argumentsJSON: json
        ))]
    }

    private mutating func completeMessage() throws -> [LLMBackendEvent] {
        guard let stopReason, blocks.allSatisfy(\.stopped) else {
            throw messagesFailure("stream.interrupted", "message_stop arrived before blocks or stop reason completed")
        }
        let privateBlocks: [MessagesPrivateBlock] = blocks.map { block in
            switch block.kind {
            case .text: .text(block.value)
            case .thinking: .thinking(thinking: block.value, signature: block.signature)
            case let .tool(id, name): .toolUse(id: id, name: name, inputJSON: block.value)
            }
        }
        let callIDs = privateBlocks.compactMap(\.toolCallID)
        guard (stopReason == "tool_use") == !callIDs.isEmpty else {
            throw messagesFailure(
                "cloud_adapter.terminal_invalid",
                "Messages stop reason does not match its tool-use batch"
            )
        }
        terminal = true
        assistantBlocks = callIDs.isEmpty ? nil : privateBlocks
        return [.generationCompleted(LLMBackendCompletion(
            outcome: callIDs.isEmpty ? .finalResponse : .toolCallsReady,
            orderedCallIDs: callIDs,
            finishReason: callIDs.isEmpty ? mapMessagesFinish(stopReason) : .toolCalls
        ))]
    }
}

private let messagesKnownEvents: Set<String> = [
    "content_block_delta", "content_block_start", "content_block_stop",
    "error", "message_delta", "message_start", "message_stop", "ping",
]

private func messagesObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= 1_024 * 1_024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw messagesFailure("cloud_adapter.event_invalid", "Messages event JSON is invalid") }
    return object
}

private func messagesProviderError(
    _ object: [String: Any],
    providerSemanticID: String
) -> LLMFailure {
    let error = object["error"] as? [String: Any] ?? object
    let type = (error["type"] as? String ?? "").lowercased()
    let diagnostics = ["provider_semantic_id": providerSemanticID]
    if type.contains("auth") {
        return messagesFailure(
            "cloud_transport.unauthorized",
            "provider rejected the credential",
            redactedDiagnostics: diagnostics
        )
    }
    if type.contains("rate") || type.contains("quota") {
        return messagesFailure(
            "cloud_transport.rate_limited",
            "provider rate limit was reached",
            retryable: true,
            recoveryAction: .retry,
            redactedDiagnostics: diagnostics
        )
    }
    return messagesFailure(
        "cloud_adapter.provider_stream_error",
        "provider emitted a Messages streaming error",
        redactedDiagnostics: diagnostics
    )
}

private func messagesInput(
    _ input: AgentLLMInput
) throws -> (system: String, messages: [[String: Any]]) {
    var system: [String] = []
    var messages: [[String: Any]] = []
    for message in input.messages {
        var text = ""
        for part in message.content {
            guard case let .text(value) = part else {
                throw messagesFailure(
                    "capability.cloud_attachment_path_unavailable",
                    "cloud attachment byte transport is unavailable in Phase 3"
                )
            }
            text += value
        }
        if message.role == .system {
            system.append(text)
        } else {
            guard message.role == .user || message.role == .assistant else {
                throw messagesFailure("cloud_adapter.message_invalid", "tool messages require envelopes")
            }
            messages.append([
                "role": message.role.rawValue,
                "content": [["type": "text", "text": text]],
            ])
        }
    }
    return (system.joined(separator: "\n\n"), messages)
}

private func messagesHistory(_ value: CanonicalJSONValue) throws -> [[String: Any]] {
    let object = try messagesFoundationObject(value)
    if let values = object as? [[String: Any]] { return values }
    if let values = object as? [Any], values.isEmpty { return [] }
    throw messagesFailure(
        "cloud_adapter.semantic_history_invalid",
        "Messages semantic history must contain complete message objects"
    )
}

private func toolResultBlocks(_ results: [NormalizedToolResult]) throws -> [[String: Any]] {
    try results.map { result in
        let content: String
        if case let .string(value) = result.result {
            content = value
        } else {
            content = String(decoding: try JSONSerialization.data(
                withJSONObject: messagesFoundationObject(result.result),
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), as: UTF8.self)
        }
        return [
            "type": "tool_result",
            "tool_use_id": result.callID,
            "content": content,
            "is_error": result.isError,
        ]
    }
}

private func messagesTools(_ schema: CanonicalJSONValue) throws -> [[String: Any]] {
    guard let object = try messagesFoundationObject(schema) as? [String: Any],
          let values = object["tools"] as? [Any]
    else { return [] }
    return try values.map { value in
        if let name = value as? String {
            return [
                "name": name,
                "input_schema": ["type": "object", "properties": [:]],
            ]
        }
        guard let value = value as? [String: Any] else {
            throw messagesFailure("cloud_adapter.tool_schema_invalid", "Messages tool schema is invalid")
        }
        return value
    }
}

private func messagesFoundationObject(_ value: CanonicalJSONValue) throws -> Any {
    try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    )
}

private func applyMessagesParameters(
    _ configuration: GenerationConfiguration,
    semantics: MessagesProviderSemantics,
    body: inout [String: Any]
) throws -> (summarized: Bool, thinking: Bool) {
    let common = Set([
        LLMParameterID.samplingTemperature.rawValue,
        LLMParameterID.samplingTopP.rawValue,
        LLMParameterID.generationMaxOutputTokens.rawValue,
        LLMParameterID.reasoningTokenBudget.rawValue,
    ])
    var supported = common
    if semantics == .anthropic {
        supported.formUnion([
            LLMParameterID.samplingTopK.rawValue,
            LLMParameterID.generationStopSequences.rawValue,
            "thinking.display",
        ])
    }
    guard Set(configuration.parameters.keys).isSubset(of: supported) else {
        throw messagesFailure(
            "cloud_adapter.parameter_unsupported",
            "Messages adapter received an unsupported canonical parameter"
        )
    }
    if let value = configuration.value(for: .samplingTemperature) {
        body["temperature"] = try messagesDecimal(value, range: 0...1)
    }
    if let value = configuration.value(for: .samplingTopP) {
        body["top_p"] = try messagesDecimal(value, range: 0...1)
    }
    if let value = configuration.value(for: .samplingTopK) {
        guard case let .integer(number) = value, number > 0 else { throw messagesParameterFailure() }
        body["top_k"] = number
    }
    if let value = configuration.value(for: .generationStopSequences) {
        guard case let .textList(items) = value, !items.isEmpty else { throw messagesParameterFailure() }
        body["stop_sequences"] = items
    }
    let maxTokens = configuration.value(for: .generationMaxOutputTokens)
    if let maxTokens {
        guard case let .integer(number) = maxTokens, number > 0 else { throw messagesParameterFailure() }
        body["max_tokens"] = number
    } else {
        body["max_tokens"] = 1_024
    }
    var thinking = false
    if let value = configuration.value(for: .reasoningTokenBudget) {
        guard case let .integer(budget) = value, budget > 0 else { throw messagesParameterFailure() }
        body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        thinking = true
    }
    var summarized = false
    if let display = configuration.parameters["thinking.display"] {
        guard case let .text(value) = display,
              value == "summarized" || value == "omitted",
              thinking
        else { throw messagesParameterFailure() }
        summarized = value == "summarized"
    }
    return (summarized, thinking)
}

private func messagesDecimal(
    _ value: LLMParameterValue,
    range: ClosedRange<Double>
) throws -> Double {
    guard case let .decimal(number) = value, number.isFinite, range.contains(number) else {
        throw messagesParameterFailure()
    }
    return number
}

private func messagesParameterFailure() -> LLMFailure {
    messagesFailure("cloud_adapter.parameter_invalid", "Messages parameter value is invalid")
}

private func messagesIndex(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
}

private func messagesUnsigned(_ value: Any?) -> UInt64? {
    guard let value = messagesIndex(value), value >= 0 else { return nil }
    return UInt64(value)
}

private func mapMessagesFinish(_ value: String) -> LLMFinishReason {
    switch value {
    case "end_turn", "stop_sequence": .stop
    case "max_tokens": .length
    case "refusal": .contentFiltered
    default: .other
    }
}

private func yieldMessages(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued: return
    case .dropped:
        throw messagesFailure(
            "cloud_adapter.consumer_backpressure",
            "Messages consumer exceeded its bounded event buffer"
        )
    case .terminated: throw CancellationError()
    @unknown default:
        throw messagesFailure(
            "cloud_adapter.consumer_backpressure",
            "Messages consumer state is unknown"
        )
    }
}

package func messagesFailure(
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
