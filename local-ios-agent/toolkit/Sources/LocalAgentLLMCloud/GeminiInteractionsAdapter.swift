import Foundation
import LocalAgentLLMContracts

package struct GeminiInteractionsAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .gemini
    package let adapterID = "gemini.interactions"
    package let adapterVersion = "1"

    package init() {}

    package func makeDiscoveryRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.modelDiscovery(encoderID: "gemini_interactions")
    }

    package func makeAccountValidationRequest() throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.accountValidation(encoderID: "gemini_interactions")
    }

    package func makeModelValidationRequest(modelID: String) throws -> CloudWireRequest {
        try ProviderProbeWireEncoder.geminiModelValidation(
            encoderID: "gemini_interactions",
            modelID: modelID
        )
    }

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try GeminiInteractionsSession(context: context)
    }
}

private enum GeminiPrivateStep: Sendable {
    case thought(summary: [String], signature: String)
    case modelOutput(text: String)
    case functionCall(id: String, name: String, argumentsJSON: String)

    var functionCallID: String? {
        guard case let .functionCall(id, _, _) = self else { return nil }
        return id
    }

    var hasMissingThoughtSignature: Bool {
        guard case let .thought(_, signature) = self else { return false }
        return signature.isEmpty
    }

    func wireObject() throws -> [String: Any] {
        switch self {
        case let .thought(summary, signature):
            return [
                "type": "thought",
                "signature": signature,
                "summary": summary.map { ["type": "text", "text": $0] },
            ]
        case let .modelOutput(text):
            return [
                "type": "model_output",
                "content": [["type": "text", "text": text]],
            ]
        case let .functionCall(id, name, argumentsJSON):
            guard let data = argumentsJSON.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(
                      with: data,
                      options: [.fragmentsAllowed]
                  )
            else {
                throw geminiFailure(
                    "cloud_adapter.tool_arguments_invalid",
                    "Gemini function arguments are not complete JSON"
                )
            }
            return [
                "type": "function_call",
                "id": id,
                "name": name,
                "arguments": arguments,
            ]
        }
    }
}

private struct GeminiContinuationState: Sendable {
    var interactionID: String?
    var steps: [GeminiPrivateStep] = []
}

package final class GeminiInteractionsSession: CloudProviderSession, @unchecked Sendable {
    private let lock = NSLock()
    private let context: CloudProviderSessionContext
    private var continuation = GeminiContinuationState()
    private var decodeTask: Task<Void, Never>?
    private var closed = false

    package init(context: CloudProviderSessionContext) throws {
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
            throw geminiFailure(
                "cloud_adapter.context_invalid",
                "Gemini session context is incomplete"
            )
        }
        self.context = context
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
            pair.continuation.finish(throwing: geminiFailure(
                "cloud_adapter.session_busy",
                "Gemini session already has an active generation"
            ))
            return pair.stream
        }
        let task = Task { [weak self] in
            guard let self else {
                pair.continuation.finish(throwing: geminiFailure(
                    "cloud_adapter.session_closed",
                    "Gemini session was released"
                ))
                return
            }
            var decoder = GeminiInteractionsDecoder(expectedModelID: self.context.modelID)
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    for output in try decoder.consume(event) {
                        try yieldGemini(output, to: pair.continuation)
                    }
                }
                try decoder.finish()
                self.record(decoder.continuation)
                pair.continuation.finish()
            } catch is CancellationError {
                _ = pair.continuation.yield(.cancelled)
                pair.continuation.finish()
            } catch let failure as LLMFailure {
                pair.continuation.finish(throwing: failure)
            } catch {
                pair.continuation.finish(throwing: geminiFailure(
                    "cloud_adapter.stream_invalid",
                    "Gemini interaction stream could not be decoded"
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
            continuation = GeminiContinuationState()
            return task
        }
        task?.cancel()
    }

    private func encode(_ turn: AuthorizedCloudGenerationTurn) throws -> CloudWireRequest {
        let state = lock.withLock { (closed, continuation) }
        guard !state.0 else {
            throw geminiFailure("cloud_adapter.session_closed", "Gemini session is closed")
        }
        try validate(turn)
        guard context.modelID.lowercased().hasPrefix("gemini-") else {
            throw geminiFailure(
                "cloud_adapter.model_incompatible",
                "Gemini adapter requires a Gemini model"
            )
        }

        let usesProviderState = context.retentionMode == .providerStateApproved
        let input = try geminiInput(turn.validated.semantic.input)
        var steps: [[String: Any]] = []
        if !usesProviderState || state.1.interactionID == nil {
            steps.append(contentsOf: try geminiHistory(
                turn.validated.semantic.providerRequiredSemanticHistory
            ))
        }
        if !usesProviderState {
            guard !state.1.steps.contains(where: \.hasMissingThoughtSignature) else {
                throw geminiFailure(
                    "cloud_adapter.continuation_signature_missing",
                    "stateless Gemini continuation requires every thought signature"
                )
            }
            steps.append(contentsOf: try state.1.steps.map { try $0.wireObject() })
        }
        steps.append(contentsOf: input.steps)

        let results = turn.validated.semantic.toolResults
        let expected = state.1.steps.compactMap(\.functionCallID)
        if !expected.isEmpty || !results.isEmpty {
            let supplied = results.map(\.callID)
            guard expected == supplied else {
                throw geminiFailure(
                    "cloud_adapter.tool_result_batch_mismatch",
                    "Gemini function-result batch does not match the ordered calls"
                )
            }
            steps.append(contentsOf: try geminiFunctionResults(results))
        }

        var body: [String: Any] = [
            "input": steps,
            "model": context.modelID,
            "store": usesProviderState,
            "stream": true,
        ]
        if !input.systemInstruction.isEmpty {
            body["system_instruction"] = input.systemInstruction
        }
        let tools = try geminiTools(turn.validated.semantic.canonicalToolSchema)
        if !tools.isEmpty { body["tools"] = tools }
        let generationConfig = try geminiGenerationConfig(
            turn.validated.semantic.resolvedParameters
        )
        if !generationConfig.isEmpty { body["generation_config"] = generationConfig }
        if usesProviderState, let interactionID = state.1.interactionID {
            body["previous_interaction_id"] = interactionID
        }

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw geminiFailure(
                "cloud_adapter.request_invalid",
                "Gemini interaction request could not be encoded"
            )
        }
        return try CloudWireRequest(
            method: "POST",
            path: "/interactions",
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
            throw geminiFailure(
                "cloud_adapter.session_mismatch",
                "authorized turn does not match the exact Gemini session"
            )
        }
        guard turn.validated.semantic.resolvedAttachments.isEmpty,
              turn.validated.semantic.input.messages.allSatisfy({ message in
                  message.content.allSatisfy { part in
                      if case .text = part { return true }
                      return false
                  }
              })
        else {
            throw geminiFailure(
                "capability.cloud_attachment_path_unavailable",
                "cloud attachment byte transport is unavailable in Phase 3"
            )
        }
    }

    private func record(_ value: GeminiContinuationState) {
        lock.withLock { if !closed { continuation = value } }
    }

    private func clearDecodeTask() { lock.withLock { decodeTask = nil } }
}

private struct GeminiInteractionsDecoder {
    private struct PartialStep {
        enum Kind {
            case modelOutput
            case thought
            case functionCall(id: String, name: String)
            case unknown
        }

        let kind: Kind
        var text = ""
        var summaries: [String] = []
        var signature = ""
        var stopped = false
    }

    let expectedModelID: String
    private(set) var continuation = GeminiContinuationState()
    private var partialSteps: [PartialStep] = []
    private var terminal = false

    init(expectedModelID: String) {
        self.expectedModelID = expectedModelID
    }

    mutating func consume(_ event: SSEEvent) throws -> [LLMBackendEvent] {
        if terminal {
            if event.event == "done", event.data == Data("[DONE]".utf8) { return [] }
            throw geminiFailure(
                "cloud_adapter.terminal_duplicate",
                "Gemini stream emitted data after its interaction terminal"
            )
        }
        guard event.event != "done" else {
            throw geminiFailure(
                "stream.interrupted",
                "Gemini done marker arrived before interaction.completed"
            )
        }
        let known = event.event.map(geminiKnownEvents.contains) ?? true
        if !known { return [] }
        let object = try geminiObject(event.data)
        let type = event.event ?? object["event_type"] as? String
        switch type {
        case "interaction.created":
            try consumeCreated(object)
            return []
        case "interaction.status_update":
            try consumeStatusUpdate(object)
            return []
        case "step.start":
            return try startStep(object)
        case "step.delta":
            return try deltaStep(object)
        case "step.stop":
            return try stopStep(object)
        case "interaction.completed":
            return try completeInteraction(object)
        case "error":
            throw geminiProviderError(object)
        case nil:
            return []
        default:
            return []
        }
    }

    func finish() throws {
        guard terminal else {
            throw geminiFailure(
                "stream.interrupted",
                "Gemini SSE ended before interaction.completed"
            )
        }
    }

    private mutating func consumeCreated(_ object: [String: Any]) throws {
        guard continuation.interactionID == nil,
              let interaction = object["interaction"] as? [String: Any],
              let id = interaction["id"] as? String, !id.isEmpty
        else {
            throw geminiFailure("cloud_adapter.event_invalid", "Gemini creation event is invalid")
        }
        if let model = interaction["model"] as? String, model != expectedModelID {
            throw geminiFailure(
                "cloud_adapter.model_mismatch",
                "Gemini response model does not match the selected model"
            )
        }
        continuation.interactionID = id
    }

    private func consumeStatusUpdate(_ object: [String: Any]) throws {
        guard let status = object["status"] as? String,
              geminiStatuses.contains(status)
        else {
            throw geminiFailure("cloud_adapter.event_invalid", "Gemini status update is invalid")
        }
    }

    private mutating func startStep(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard partialSteps.allSatisfy(\.stopped),
              let index = geminiIndex(object["index"]), index == partialSteps.count,
              let step = object["step"] as? [String: Any],
              let type = step["type"] as? String
        else {
            throw geminiFailure(
                "cloud_adapter.step_index_invalid",
                "Gemini step index or lifecycle is invalid"
            )
        }
        switch type {
        case "model_output":
            partialSteps.append(PartialStep(kind: .modelOutput))
            return []
        case "thought":
            partialSteps.append(PartialStep(kind: .thought))
            return []
        case "function_call":
            guard let id = step["id"] as? String, !id.isEmpty,
                  let name = step["name"] as? String, !name.isEmpty
            else {
                throw geminiFailure(
                    "cloud_adapter.tool_call_invalid",
                    "Gemini function-call identity is invalid"
                )
            }
            partialSteps.append(PartialStep(kind: .functionCall(id: id, name: name)))
            return [.toolCallStarted(callID: id, name: name)]
        default:
            partialSteps.append(PartialStep(kind: .unknown))
            return []
        }
    }

    private mutating func deltaStep(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let index = geminiIndex(object["index"]),
              partialSteps.indices.contains(index),
              !partialSteps[index].stopped,
              let delta = object["delta"] as? [String: Any],
              let type = delta["type"] as? String
        else {
            throw geminiFailure(
                "cloud_adapter.step_index_invalid",
                "Gemini step delta index or lifecycle is invalid"
            )
        }
        switch (partialSteps[index].kind, type) {
        case (.modelOutput, "text"):
            let value = delta["text"] as? String ?? ""
            partialSteps[index].text += value
            return value.isEmpty ? [] : [.textDelta(value)]
        case (.thought, "thought_summary"):
            guard let content = delta["content"] as? [String: Any],
                  content["type"] as? String == "text",
                  let value = content["text"] as? String
            else {
                throw geminiFailure(
                    "cloud_adapter.thought_summary_invalid",
                    "Gemini thought summary content is unsupported"
                )
            }
            partialSteps[index].summaries.append(value)
            return value.isEmpty ? [] : [.reasoningSummaryDelta(value)]
        case (.thought, "thought_signature"):
            partialSteps[index].signature += delta["signature"] as? String ?? ""
            return []
        case let (.functionCall(id, _), "arguments_delta"):
            let value = delta["arguments"] as? String ?? ""
            partialSteps[index].text += value
            return value.isEmpty ? [] : [.toolCallArgumentsDelta(callID: id, delta: value)]
        case (.unknown, _):
            return []
        default:
            throw geminiFailure(
                "cloud_adapter.step_delta_invalid",
                "Gemini step delta does not match its step type"
            )
        }
    }

    private mutating func stopStep(_ object: [String: Any]) throws -> [LLMBackendEvent] {
        guard let index = geminiIndex(object["index"]),
              partialSteps.indices.contains(index),
              !partialSteps[index].stopped
        else {
            throw geminiFailure(
                "cloud_adapter.step_index_invalid",
                "Gemini step stop index or lifecycle is invalid"
            )
        }
        partialSteps[index].stopped = true
        guard case let .functionCall(id, name) = partialSteps[index].kind else { return [] }
        let arguments = partialSteps[index].text
        guard let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]
              )) != nil
        else {
            throw geminiFailure(
                "cloud_adapter.tool_arguments_invalid",
                "Gemini function arguments are not complete JSON"
            )
        }
        return [.toolCallCompleted(NormalizedToolCall(
            callID: id,
            name: name,
            argumentsJSON: arguments
        ))]
    }

    private mutating func completeInteraction(
        _ object: [String: Any]
    ) throws -> [LLMBackendEvent] {
        guard partialSteps.allSatisfy(\.stopped),
              let interaction = object["interaction"] as? [String: Any],
              let status = interaction["status"] as? String,
              geminiStatuses.contains(status)
        else {
            throw geminiFailure(
                "stream.interrupted",
                "Gemini interaction terminal is incomplete"
            )
        }
        if let id = interaction["id"] as? String, !id.isEmpty {
            if let existing = continuation.interactionID, existing != id {
                throw geminiFailure(
                    "cloud_adapter.interaction_mismatch",
                    "Gemini terminal interaction identity changed"
                )
            }
            continuation.interactionID = id
        }
        switch status {
        case "failed":
            terminal = true
            throw geminiFailure(
                "cloud_adapter.generation_failed",
                "Gemini interaction failed",
                retryable: true,
                recoveryAction: .retry
            )
        case "cancelled":
            terminal = true
            continuation = GeminiContinuationState()
            return [.cancelled]
        case "incomplete":
            terminal = true
            throw geminiFailure(
                "cloud_adapter.generation_incomplete",
                "Gemini interaction ended with incomplete output",
                retryable: true,
                recoveryAction: .retry
            )
        case "budget_exceeded":
            terminal = true
            throw geminiFailure(
                "cloud_adapter.token_budget_exceeded",
                "Gemini interaction exceeded its token budget"
            )
        case "requires_action", "completed":
            break
        default:
            throw geminiFailure(
                "cloud_adapter.terminal_invalid",
                "Gemini interaction completed with a non-terminal status"
            )
        }

        let steps = partialSteps.compactMap { step -> GeminiPrivateStep? in
            switch step.kind {
            case .modelOutput:
                return .modelOutput(text: step.text)
            case .thought:
                return .thought(summary: step.summaries, signature: step.signature)
            case let .functionCall(id, name):
                return .functionCall(id: id, name: name, argumentsJSON: step.text)
            case .unknown:
                return nil
            }
        }
        let callIDs = steps.compactMap(\.functionCallID)
        guard (status == "requires_action") == !callIDs.isEmpty else {
            throw geminiFailure(
                "cloud_adapter.terminal_invalid",
                "Gemini status does not match its function-call batch"
            )
        }
        continuation.steps = steps
        terminal = true
        var output: [LLMBackendEvent] = []
        if let usage = interaction["usage"] as? [String: Any] {
            output.append(.usageUpdated(LLMUsage(
                inputTokens: geminiUnsigned(usage["total_input_tokens"]),
                outputTokens: geminiUnsigned(usage["total_output_tokens"])
            )))
        }
        output.append(.generationCompleted(LLMBackendCompletion(
            outcome: callIDs.isEmpty ? .finalResponse : .toolCallsReady,
            orderedCallIDs: callIDs,
            finishReason: callIDs.isEmpty ? .stop : .toolCalls
        )))
        return output
    }
}

private let geminiKnownEvents: Set<String> = [
    "error", "interaction.completed", "interaction.created",
    "interaction.status_update", "step.delta", "step.start", "step.stop",
]

private let geminiStatuses: Set<String> = [
    "budget_exceeded", "cancelled", "completed", "failed", "in_progress",
    "incomplete", "requires_action",
]

private func geminiObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= 1_024 * 1_024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw geminiFailure(
            "cloud_adapter.event_invalid",
            "Gemini streaming event JSON is invalid"
        )
    }
    return object
}

private func geminiProviderError(_ object: [String: Any]) -> LLMFailure {
    let error = object["error"] as? [String: Any] ?? object
    let code = (error["code"] as? String ?? "").lowercased()
    let diagnostics = ["provider_semantic_id": "gemini.interactions"]
    if code.contains("auth") || code.contains("permission") {
        return geminiFailure(
            "cloud_transport.unauthorized",
            "provider rejected the credential",
            redactedDiagnostics: diagnostics
        )
    }
    if code.contains("resource_exhausted") || code.contains("rate") || code.contains("quota") {
        return geminiFailure(
            "cloud_transport.rate_limited",
            "provider rate limit was reached",
            retryable: true,
            recoveryAction: .retry,
            redactedDiagnostics: diagnostics
        )
    }
    return geminiFailure(
        "cloud_adapter.provider_stream_error",
        "provider emitted a Gemini streaming error",
        redactedDiagnostics: diagnostics
    )
}

private func geminiInput(
    _ input: AgentLLMInput
) throws -> (systemInstruction: String, steps: [[String: Any]]) {
    var system: [String] = []
    var steps: [[String: Any]] = []
    for message in input.messages {
        var text = ""
        for part in message.content {
            guard case let .text(value) = part else {
                throw geminiFailure(
                    "capability.cloud_attachment_path_unavailable",
                    "cloud attachment byte transport is unavailable in Phase 3"
                )
            }
            text += value
        }
        switch message.role {
        case .system:
            system.append(text)
        case .user:
            steps.append([
                "type": "user_input",
                "content": [["type": "text", "text": text]],
            ])
        case .assistant:
            steps.append([
                "type": "model_output",
                "content": [["type": "text", "text": text]],
            ])
        case .tool:
            throw geminiFailure(
                "cloud_adapter.message_invalid",
                "Gemini tool results require normalized result envelopes"
            )
        }
    }
    return (system.joined(separator: "\n\n"), steps)
}

private func geminiHistory(_ value: CanonicalJSONValue) throws -> [[String: Any]] {
    let object = try geminiFoundationObject(value)
    if let steps = object as? [[String: Any]] { return steps }
    if let values = object as? [Any], values.isEmpty { return [] }
    throw geminiFailure(
        "cloud_adapter.semantic_history_invalid",
        "Gemini semantic history must contain complete interaction steps"
    )
}

private func geminiFunctionResults(
    _ results: [NormalizedToolResult]
) throws -> [[String: Any]] {
    try results.map { result in
        let text: String
        if case let .string(value) = result.result {
            text = value
        } else {
            text = String(decoding: try JSONSerialization.data(
                withJSONObject: geminiFoundationObject(result.result),
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), as: UTF8.self)
        }
        return [
            "type": "function_result",
            "call_id": result.callID,
            "name": result.toolName,
            "result": [["type": "text", "text": text]],
            "is_error": result.isError,
        ]
    }
}

private func geminiTools(_ schema: CanonicalJSONValue) throws -> [[String: Any]] {
    guard let object = try geminiFoundationObject(schema) as? [String: Any],
          let tools = object["tools"] as? [Any]
    else { return [] }
    return try tools.map { value in
        if let name = value as? String {
            return [
                "type": "function",
                "name": name,
                "parameters": ["type": "object", "properties": [:]],
            ]
        }
        guard var tool = value as? [String: Any] else {
            throw geminiFailure(
                "cloud_adapter.tool_schema_invalid",
                "Gemini function schema is invalid"
            )
        }
        tool["type"] = "function"
        return tool
    }
}

private func geminiGenerationConfig(
    _ configuration: GenerationConfiguration
) throws -> [String: Any] {
    let supported = Set([
        LLMParameterID.samplingTemperature.rawValue,
        LLMParameterID.samplingTopP.rawValue,
        LLMParameterID.generationMaxOutputTokens.rawValue,
        LLMParameterID.generationSeed.rawValue,
        LLMParameterID.generationStopSequences.rawValue,
        LLMParameterID.reasoningEffort.rawValue,
        "thinking.display",
    ])
    guard Set(configuration.parameters.keys).isSubset(of: supported) else {
        throw geminiFailure(
            "cloud_adapter.parameter_unsupported",
            "Gemini adapter received an unsupported canonical parameter"
        )
    }
    var output: [String: Any] = [:]
    if let value = configuration.value(for: .samplingTemperature) {
        output["temperature"] = try geminiDecimal(value, range: 0...2)
    }
    if let value = configuration.value(for: .samplingTopP) {
        output["top_p"] = try geminiDecimal(value, range: 0...1)
    }
    if let value = configuration.value(for: .generationMaxOutputTokens) {
        output["max_output_tokens"] = try geminiPositiveInteger(value)
    }
    if let value = configuration.value(for: .generationSeed) {
        guard case let .integer(number) = value else { throw geminiParameterFailure() }
        output["seed"] = number
    }
    if let value = configuration.value(for: .generationStopSequences) {
        guard case let .textList(items) = value, !items.isEmpty else {
            throw geminiParameterFailure()
        }
        output["stop_sequences"] = items
    }
    if let value = configuration.value(for: .reasoningEffort) {
        guard case let .text(level) = value,
              ["minimal", "low", "medium", "high"].contains(level)
        else { throw geminiParameterFailure() }
        output["thinking_level"] = level
    }
    if let value = configuration.parameters["thinking.display"] {
        guard case let .text(display) = value,
              display == "summarized" || display == "omitted"
        else { throw geminiParameterFailure() }
        output["thinking_summaries"] = display == "summarized" ? "auto" : "none"
    }
    return output
}

private func geminiFoundationObject(_ value: CanonicalJSONValue) throws -> Any {
    try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    )
}

private func geminiDecimal(
    _ value: LLMParameterValue,
    range: ClosedRange<Double>
) throws -> Double {
    guard case let .decimal(number) = value,
          number.isFinite,
          range.contains(number)
    else { throw geminiParameterFailure() }
    return number
}

private func geminiPositiveInteger(_ value: LLMParameterValue) throws -> Int64 {
    guard case let .integer(number) = value, number > 0 else {
        throw geminiParameterFailure()
    }
    return number
}

private func geminiParameterFailure() -> LLMFailure {
    geminiFailure("cloud_adapter.parameter_invalid", "Gemini parameter value is invalid")
}

private func geminiIndex(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
}

private func geminiUnsigned(_ value: Any?) -> UInt64? {
    guard let value = geminiIndex(value), value >= 0 else { return nil }
    return UInt64(value)
}

private func yieldGemini(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued:
        return
    case .dropped:
        throw geminiFailure(
            "cloud_adapter.consumer_backpressure",
            "Gemini consumer exceeded its bounded event buffer"
        )
    case .terminated:
        throw CancellationError()
    @unknown default:
        throw geminiFailure(
            "cloud_adapter.consumer_backpressure",
            "Gemini consumer state is unknown"
        )
    }
}

private func geminiFailure(
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
