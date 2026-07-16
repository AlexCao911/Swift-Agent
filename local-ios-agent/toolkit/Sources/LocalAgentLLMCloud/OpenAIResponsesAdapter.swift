import Foundation
import LocalAgentLLMContracts

package struct OpenAIResponsesAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .openAI
    package let adapterID = "openai.responses"
    package let adapterVersion = "1"

    package init() {}

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try OpenAIResponsesSession(context: context, semantics: .openAI)
    }
}

package enum ResponsesProviderSemantics: Sendable {
    case openAI
    case xAI

    var semanticAdapterID: String {
        switch self {
        case .openAI: "openai.responses"
        case .xAI: "xai.responses"
        }
    }
}

package final class OpenAIResponsesSession: CloudProviderSession, @unchecked Sendable {
    private struct ContinuationState: Sendable {
        var responseID: String?
        var encryptedReasoning: [String] = []
    }

    private let lock = NSLock()
    private let context: CloudProviderSessionContext
    private let semantics: ResponsesProviderSemantics
    private var continuationState = ContinuationState()
    private var decodeTask: Task<Void, Never>?
    private var closed = false

    package init(
        context: CloudProviderSessionContext,
        semantics: ResponsesProviderSemantics
    ) throws {
        guard !context.targetID.rawValue.isEmpty,
              context.targetRevision > 0,
              !context.providerProfileID.isEmpty,
              context.providerProfileRevision > 0,
              !context.modelID.isEmpty,
              (context.retentionApprovalRevision == nil)
                == (context.retentionApprovalDigest == nil),
              context.retentionMode == .statelessRequired
                ? context.retentionApprovalRevision == nil
                : context.retentionApprovalRevision != nil
        else {
            throw responsesFailure(
                "cloud_adapter.context_invalid",
                "Responses session context is incomplete"
            )
        }
        self.context = context
        self.semantics = semantics
    }

    package func encodeStart(
        _ turn: AuthorizedCloudGenerationTurn
    ) throws -> CloudWireRequest {
        try encode(turn)
    }

    package func encodeResume(
        _ turn: AuthorizedCloudGenerationTurn
    ) throws -> CloudWireRequest {
        try encode(turn)
    }

    package func decode(
        _ events: AsyncThrowingStream<SSEEvent, Error>
    ) -> LLMBackendEventStream {
        let pair = LLMBackendEventStream.makeStream(bufferingPolicy: .bufferingOldest(32))
        lock.lock()
        guard !closed, decodeTask == nil else {
            lock.unlock()
            pair.continuation.finish(throwing: responsesFailure(
                "cloud_adapter.session_busy",
                "Responses session already has an active generation"
            ))
            return pair.stream
        }
        let task = Task { [weak self] in
            guard let self else {
                pair.continuation.finish(throwing: responsesFailure(
                    "cloud_adapter.session_closed",
                    "Responses session was released"
                ))
                return
            }
            var decoder = OpenAIResponsesDecoder(
                providerSemanticID: self.semantics.semanticAdapterID
            )
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    for output in try decoder.consume(event) {
                        try yield(output, to: pair.continuation)
                    }
                }
                try decoder.finish()
                self.recordContinuation(
                    responseID: decoder.responseID,
                    encryptedReasoning: decoder.encryptedReasoning
                )
                pair.continuation.finish()
            } catch is CancellationError {
                _ = pair.continuation.yield(.cancelled)
                pair.continuation.finish()
            } catch let failure as LLMFailure {
                pair.continuation.finish(throwing: failure)
            } catch {
                pair.continuation.finish(throwing: responsesFailure(
                    "cloud_adapter.stream_invalid",
                    "Responses stream could not be decoded"
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
        let task = lock.withLock { decodeTask }
        task?.cancel()
    }

    package func close() async {
        let task = lock.withLock {
            closed = true
            let task = decodeTask
            decodeTask = nil
            continuationState = ContinuationState()
            return task
        }
        task?.cancel()
    }

    private func encode(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        let state: ContinuationState
        lock.lock()
        let isClosed = closed
        state = continuationState
        lock.unlock()
        guard !isClosed else {
            throw responsesFailure("cloud_adapter.session_closed", "Responses session is closed")
        }
        try validate(turn)
        if semantics == .xAI, !context.modelID.lowercased().hasPrefix("grok-") {
            throw responsesFailure(
                "cloud_adapter.model_incompatible",
                "xAI Responses session requires a Grok model"
            )
        }

        let usesProviderState = context.retentionMode == .providerStateApproved
        var input: [Any] = []
        if !usesProviderState || state.responseID == nil {
            input.append(contentsOf: try responseHistory(
                turn.validated.semantic.providerRequiredSemanticHistory
            ))
        }
        if !usesProviderState {
            input.append(contentsOf: state.encryptedReasoning.map {
                ["type": "reasoning", "encrypted_content": $0]
            })
        }
        input.append(contentsOf: try responseMessages(turn.validated.semantic.input))
        input.append(contentsOf: try responseToolResults(turn.validated.semantic.toolResults))

        var body: [String: Any] = [
            "include": ["reasoning.encrypted_content"],
            "input": input,
            "model": context.modelID,
            "store": usesProviderState,
            "stream": true,
        ]
        let tools = try responseTools(turn.validated.semantic.canonicalToolSchema)
        if !tools.isEmpty { body["tools"] = tools }
        if usesProviderState, let responseID = state.responseID {
            body["previous_response_id"] = responseID
        }
        try applyParameters(
            turn.validated.semantic.resolvedParameters,
            semantics: semantics,
            body: &body
        )
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw responsesFailure(
                "cloud_adapter.request_invalid",
                "Responses request could not be encoded"
            )
        }
        return try CloudWireRequest(
            method: "POST",
            path: "/responses",
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
              turn.retentionMode == context.retentionMode,
              turn.retentionApprovalRevision == context.retentionApprovalRevision,
              turn.retentionApprovalDigest == context.retentionApprovalDigest
        else {
            throw responsesFailure(
                "cloud_adapter.session_mismatch",
                "authorized turn does not match the exact Responses session"
            )
        }
        guard turn.validated.semantic.resolvedAttachments.isEmpty,
              turn.validated.semantic.input.messages.allSatisfy({ message in
                  message.content.allSatisfy { content in
                      if case .text = content { return true }
                      return false
                  }
              })
        else {
            throw responsesFailure(
                "capability.cloud_attachment_path_unavailable",
                "cloud attachment byte transport is unavailable in Phase 3"
            )
        }
    }

    private func recordContinuation(responseID: String?, encryptedReasoning: [String]) {
        lock.lock()
        if !closed {
            continuationState.responseID = responseID
            continuationState.encryptedReasoning = encryptedReasoning
        }
        lock.unlock()
    }

    private func clearDecodeTask() {
        lock.lock()
        decodeTask = nil
        lock.unlock()
    }
}

private struct OpenAIResponsesDecoder {
    private struct ToolState {
        let itemID: String
        let callID: String
        let name: String
        var arguments = ""
        var completed = false
    }

    let providerSemanticID: String
    private(set) var responseID: String?
    private(set) var encryptedReasoning: [String] = []
    private var tools: [ToolState] = []
    private var terminal = false

    init(providerSemanticID: String) {
        self.providerSemanticID = providerSemanticID
    }

    mutating func consume(_ event: SSEEvent) throws -> [LLMBackendEvent] {
        guard !terminal else {
            throw responsesFailure(
                "cloud_adapter.terminal_duplicate",
                "Responses stream emitted data after its terminal event"
            )
        }
        let named = event.event
        if let named, !knownResponseEvents.contains(named) { return [] }
        let object = try responseObject(event.data)
        guard let type = named ?? object["type"] as? String else {
            throw responsesFailure("cloud_adapter.event_invalid", "Responses event type is missing")
        }
        switch type {
        case "response.created", "response.in_progress":
            recordResponseID(object)
            return []
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else {
                throw responsesFailure("cloud_adapter.event_invalid", "text delta is missing")
            }
            return delta.isEmpty ? [] : [.textDelta(delta)]
        case "response.reasoning_summary_text.delta", "response.reasoning_summary.delta":
            guard let delta = object["delta"] as? String else {
                throw responsesFailure("cloud_adapter.event_invalid", "reasoning summary delta is missing")
            }
            return delta.isEmpty ? [] : [.reasoningSummaryDelta(delta)]
        case "response.reasoning_text.delta", "response.reasoning.delta":
            return []
        case "response.output_item.added":
            return try addOutputItem(object)
        case "response.output_item.done":
            return try finishOutputItem(object)
        case "response.function_call_arguments.delta":
            return try addArguments(object)
        case "response.function_call_arguments.done":
            return try finishArguments(object)
        case "response.completed":
            return try complete(object)
        case "response.failed", "response.incomplete":
            terminal = true
            throw responsesFailure(
                "cloud_adapter.provider_terminal_failure",
                "provider ended the Responses generation without completion",
                retryable: type == "response.incomplete",
                recoveryAction: type == "response.incomplete" ? .retry : nil,
                redactedDiagnostics: ["provider_semantic_id": providerSemanticID]
            )
        case "response.cancelled":
            terminal = true
            recordResponseID(object)
            return [.cancelled]
        case "error":
            terminal = true
            throw providerError(object)
        default:
            return []
        }
    }

    mutating func finish() throws {
        guard terminal else {
            throw responsesFailure(
                "cloud_adapter.terminal_missing",
                "Responses stream ended without a provider terminal event"
            )
        }
    }

    private mutating func addOutputItem(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let item = object["item"] as? [String: Any],
              let type = item["type"] as? String
        else { throw responsesFailure("cloud_adapter.event_invalid", "output item is invalid") }
        if type == "reasoning" {
            if let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty {
                encryptedReasoning.append(encrypted)
            }
            return []
        }
        guard type == "function_call" else { return [] }
        guard let itemID = item["id"] as? String, !itemID.isEmpty,
              let callID = item["call_id"] as? String, !callID.isEmpty,
              let name = item["name"] as? String, !name.isEmpty,
              !tools.contains(where: { $0.itemID == itemID || $0.callID == callID })
        else {
            throw responsesFailure("cloud_adapter.tool_call_invalid", "function-call identity is invalid")
        }
        var state = ToolState(itemID: itemID, callID: callID, name: name)
        if let arguments = item["arguments"] as? String { state.arguments = arguments }
        tools.append(state)
        return [.toolCallStarted(callID: callID, name: name)]
    }

    private mutating func addArguments(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        let index = try toolIndex(object)
        guard !tools[index].completed, let delta = object["delta"] as? String else {
            throw responsesFailure("cloud_adapter.tool_call_invalid", "tool argument delta is invalid")
        }
        tools[index].arguments += delta
        return [.toolCallArgumentsDelta(callID: tools[index].callID, delta: delta)]
    }

    private mutating func finishArguments(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        let index = try toolIndex(object)
        if let final = object["arguments"] as? String {
            guard tools[index].arguments.isEmpty || tools[index].arguments == final else {
                throw responsesFailure(
                    "cloud_adapter.tool_arguments_invalid",
                    "final tool arguments differ from streamed fragments"
                )
            }
            tools[index].arguments = final
        }
        return try completeTool(at: index)
    }

    private mutating func finishOutputItem(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let item = object["item"] as? [String: Any] else { return [] }
        if item["type"] as? String == "reasoning",
           let encrypted = item["encrypted_content"] as? String,
           !encrypted.isEmpty,
           !encryptedReasoning.contains(encrypted) {
            encryptedReasoning.append(encrypted)
            return []
        }
        guard item["type"] as? String == "function_call" else { return [] }
        let index = try toolIndex(["item_id": item["id"] as Any])
        if let arguments = item["arguments"] as? String, tools[index].arguments.isEmpty {
            tools[index].arguments = arguments
        }
        return try completeTool(at: index)
    }

    private mutating func complete(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        recordResponseID(object)
        let response = object["response"] as? [String: Any] ?? object
        if let status = response["status"] as? String, status != "completed" {
            throw responsesFailure(
                "cloud_adapter.provider_terminal_failure",
                "provider completion carried a non-completed status"
            )
        }
        guard tools.allSatisfy(\.completed) else {
            throw responsesFailure(
                "cloud_adapter.tool_call_incomplete",
                "provider completed before every tool call was assembled"
            )
        }
        terminal = true
        var output: [LLMBackendEvent] = []
        if let usage = response["usage"] as? [String: Any] {
            output.append(.usageUpdated(LLMUsage(
                inputTokens: unsigned(usage["input_tokens"]),
                outputTokens: unsigned(usage["output_tokens"])
            )))
        }
        let callIDs = tools.map(\.callID)
        output.append(.generationCompleted(LLMBackendCompletion(
            outcome: callIDs.isEmpty ? .finalResponse : .toolCallsReady,
            orderedCallIDs: callIDs,
            finishReason: callIDs.isEmpty ? .stop : .toolCalls
        )))
        return output
    }

    private mutating func completeTool(at index: Int) throws -> [LLMBackendEvent] {
        guard !tools[index].completed else { return [] }
        let arguments = tools[index].arguments
        guard !arguments.isEmpty,
              let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
        else {
            throw responsesFailure(
                "cloud_adapter.tool_arguments_invalid",
                "tool arguments are not one complete JSON value"
            )
        }
        tools[index].completed = true
        let call = tools[index]
        return [.toolCallCompleted(NormalizedToolCall(
            callID: call.callID,
            name: call.name,
            argumentsJSON: call.arguments
        ))]
    }

    private func toolIndex(_ object: [String: Any]) throws -> Int {
        let identity = object["item_id"] as? String ?? object["call_id"] as? String
        guard let identity,
              let index = tools.firstIndex(where: {
                  $0.itemID == identity || $0.callID == identity
              })
        else {
            throw responsesFailure("cloud_adapter.tool_call_invalid", "tool call was not started")
        }
        return index
    }

    private mutating func recordResponseID(_ object: [String: Any]) {
        let response = object["response"] as? [String: Any] ?? object
        if let value = response["id"] as? String, !value.isEmpty { responseID = value }
    }

    private func providerError(_ object: [String: Any]) -> LLMFailure {
        let code = (object["code"] as? String ?? "").lowercased()
        let diagnostics = ["provider_semantic_id": providerSemanticID]
        if code.contains("api_key") || code.contains("auth") || code.contains("unauthorized") {
            return responsesFailure(
                "cloud_transport.unauthorized",
                "provider rejected the credential",
                redactedDiagnostics: diagnostics
            )
        }
        if code.contains("rate") || code.contains("quota") {
            return responsesFailure(
                "cloud_transport.rate_limited",
                "provider rate limit was reached",
                retryable: true,
                recoveryAction: .retry,
                redactedDiagnostics: diagnostics
            )
        }
        return responsesFailure(
            "cloud_adapter.provider_stream_error",
            "provider emitted a streaming error",
            redactedDiagnostics: diagnostics
        )
    }
}

private let knownResponseEvents: Set<String> = [
    "error",
    "response.cancelled",
    "response.completed",
    "response.created",
    "response.failed",
    "response.function_call_arguments.delta",
    "response.function_call_arguments.done",
    "response.in_progress",
    "response.incomplete",
    "response.output_item.added",
    "response.output_item.done",
    "response.output_text.delta",
    "response.reasoning.delta",
    "response.reasoning_summary.delta",
    "response.reasoning_summary_text.delta",
    "response.reasoning_text.delta",
]

private func responseObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= 1_024 * 1_024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw responsesFailure("cloud_adapter.event_invalid", "Responses event JSON is invalid")
    }
    return object
}

private func responseHistory(_ value: CanonicalJSONValue) throws -> [Any] {
    let object = try foundationObject(value)
    if let array = object as? [Any] { return array }
    if object is NSNull { return [] }
    throw responsesFailure(
        "cloud_adapter.semantic_history_invalid",
        "provider semantic history must be an array"
    )
}

private func responseMessages(_ input: AgentLLMInput) throws -> [[String: Any]] {
    try input.messages.map { message in
        guard message.role != .tool else {
            throw responsesFailure(
                "cloud_adapter.message_invalid",
                "tool messages must use normalized tool-result envelopes"
            )
        }
        let content: [[String: Any]] = try message.content.map { part in
            switch part {
            case let .text(text):
                return ["type": "input_text", "text": text]
            case .attachment:
                throw responsesFailure(
                    "capability.cloud_attachment_path_unavailable",
                    "cloud attachment byte transport is unavailable in Phase 3"
                )
            }
        }
        return ["type": "message", "role": message.role.rawValue, "content": content]
    }
}

private func responseToolResults(_ results: [NormalizedToolResult]) throws -> [[String: Any]] {
    try results.map { result in
        let output: String
        if case let .string(value) = result.result {
            output = value
        } else {
            let data = try JSONSerialization.data(
                withJSONObject: foundationObject(result.result),
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            output = String(decoding: data, as: UTF8.self)
        }
        return [
            "type": "function_call_output",
            "call_id": result.callID,
            "output": output,
        ]
    }
}

private func responseTools(_ schema: CanonicalJSONValue) throws -> [[String: Any]] {
    guard let object = try foundationObject(schema) as? [String: Any],
          let values = object["tools"] as? [Any]
    else { return [] }
    return try values.map { value in
        if let name = value as? String {
            return [
                "type": "function",
                "name": name,
                "parameters": ["type": "object", "properties": [:]],
            ]
        }
        guard var tool = value as? [String: Any] else {
            throw responsesFailure("cloud_adapter.tool_schema_invalid", "tool schema is invalid")
        }
        if tool["type"] == nil { tool["type"] = "function" }
        return tool
    }
}

private func foundationObject(_ value: CanonicalJSONValue) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func applyParameters(
    _ configuration: GenerationConfiguration,
    semantics: ResponsesProviderSemantics,
    body: inout [String: Any]
) throws {
    let values = configuration.parameters
    let reasoningEnabled = values[LLMParameterID.reasoningEffort.rawValue] != nil
    let xAIIncompatible = Set([
        LLMParameterID.generationStopSequences.rawValue,
        "sampling.presence_penalty",
        "sampling.frequency_penalty",
    ])
    if semantics == .xAI, reasoningEnabled,
       !Set(values.keys).intersection(xAIIncompatible).isEmpty {
        throw responsesFailure(
            "cloud_adapter.parameter_incompatible",
            "xAI reasoning mode is incompatible with the requested sampling controls"
        )
    }
    var supported = Set([
        LLMParameterID.samplingTemperature.rawValue,
        LLMParameterID.samplingTopP.rawValue,
        LLMParameterID.generationMaxOutputTokens.rawValue,
        LLMParameterID.generationStopSequences.rawValue,
        LLMParameterID.reasoningEffort.rawValue,
    ])
    if semantics == .openAI { supported.insert(LLMParameterID.outputVerbosity.rawValue) }
    guard Set(values.keys).isSubset(of: supported) else {
        throw responsesFailure(
            "cloud_adapter.parameter_unsupported",
            "Responses adapter received an unsupported canonical parameter"
        )
    }
    if let value = values[LLMParameterID.samplingTemperature.rawValue] {
        body["temperature"] = try decimal(value, range: 0...2)
    }
    if let value = values[LLMParameterID.samplingTopP.rawValue] {
        body["top_p"] = try decimal(value, range: 0...1)
    }
    if let value = values[LLMParameterID.generationMaxOutputTokens.rawValue] {
        body["max_output_tokens"] = try positiveInteger(value)
    }
    if let value = values[LLMParameterID.generationStopSequences.rawValue] {
        guard case let .textList(items) = value,
              !items.isEmpty,
              items.allSatisfy({ !$0.isEmpty })
        else { throw parameterValueFailure() }
        body["stop"] = items
    }
    if let value = values[LLMParameterID.reasoningEffort.rawValue] {
        guard case let .text(effort) = value,
              ["none", "minimal", "low", "medium", "high", "xhigh"].contains(effort)
        else { throw parameterValueFailure() }
        body["reasoning"] = ["effort": effort]
    }
    if let value = values[LLMParameterID.outputVerbosity.rawValue] {
        guard case let .text(verbosity) = value,
              ["low", "medium", "high"].contains(verbosity)
        else { throw parameterValueFailure() }
        body["text"] = ["verbosity": verbosity]
    }
}

private func decimal(_ value: LLMParameterValue, range: ClosedRange<Double>) throws -> Double {
    guard case let .decimal(number) = value, number.isFinite, range.contains(number) else {
        throw parameterValueFailure()
    }
    return number
}

private func positiveInteger(_ value: LLMParameterValue) throws -> Int64 {
    guard case let .integer(number) = value, number > 0 else { throw parameterValueFailure() }
    return number
}

private func parameterValueFailure() -> LLMFailure {
    responsesFailure(
        "cloud_adapter.parameter_invalid",
        "Responses parameter value is invalid"
    )
}

private func unsigned(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 { return value }
    if let value = value as? Int, value >= 0 { return UInt64(value) }
    if let value = value as? NSNumber, value.doubleValue >= 0,
       value.doubleValue.rounded() == value.doubleValue {
        return UInt64(value.doubleValue)
    }
    return nil
}

private func yield(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued:
        return
    case .dropped:
        throw responsesFailure(
            "cloud_adapter.consumer_backpressure",
            "Responses consumer exceeded its bounded event buffer"
        )
    case .terminated:
        throw CancellationError()
    @unknown default:
        throw responsesFailure(
            "cloud_adapter.consumer_backpressure",
            "Responses consumer state is unknown"
        )
    }
}

package func responsesFailure(
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
