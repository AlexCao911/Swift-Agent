import Foundation
import LocalAgentLLMContracts

package struct AntigravityCloudCodeAdapter: CloudProviderAdapter {
    package let presetID: ProviderPresetID = .antigravity
    package let adapterID = "antigravity.cloud_code"
    package let adapterVersion = "1"

    package init() {}

    package func makeDiscoveryRequest() throws -> CloudWireRequest {
        try setupRequest(requestClass: .discovery)
    }

    package func makeAccountValidationRequest() throws -> CloudWireRequest {
        try setupRequest(requestClass: .accountValidation)
    }

    package func makeModelValidationRequest(
        modelID _: String
    ) throws -> CloudWireRequest {
        throw antigravityFailure(
            "cloud_adapter.project_missing",
            "Antigravity model validation requires its discovered project"
        )
    }

    package func makeModelValidationRequest(
        modelID: String,
        providerProjectID: String?
    ) throws -> CloudWireRequest {
        guard let providerProjectID, !providerProjectID.isEmpty else {
            throw antigravityFailure(
                "cloud_adapter.project_missing",
                "Antigravity model validation requires its discovered project"
            )
        }
        return try generationRequest(
            modelID: modelID,
            projectID: providerProjectID,
            sessionID: UUID().uuidString.lowercased(),
            request: [
                "contents": [[
                    "role": "user",
                    "parts": [["text": "Reply with OK."]],
                ]],
                "generationConfig": ["maxOutputTokens": 8],
            ],
            provenance: .noUserData(
                presetEncoderID: "antigravity_cloud_code",
                requestClass: .modelValidation
            )
        )
    }

    package func makeSession(
        _ context: CloudProviderSessionContext
    ) throws -> any CloudProviderSession {
        try AntigravityCloudCodeSession(context: context)
    }

    private func setupRequest(
        requestClass: CloudRequestClass
    ) throws -> CloudWireRequest {
        try CloudWireRequest(
            method: "POST",
            path: "/v1internal:loadCodeAssist",
            queryItems: [],
            headers: antigravityHeaders(accept: "application/json"),
            body: try JSONSerialization.data(
                withJSONObject: [
                    "metadata": [
                        "ideType": "IDE_UNSPECIFIED",
                        "platform": "PLATFORM_UNSPECIFIED",
                        "pluginType": "GEMINI",
                    ],
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            dataProvenance: .noUserData(
                presetEncoderID: "antigravity_cloud_code",
                requestClass: requestClass
            )
        )
    }
}

package final class AntigravityCloudCodeSession:
    CloudProviderSession,
    @unchecked Sendable
{
    fileprivate struct PendingCall {
        let callID: String
        let name: String
    }

    private let lock = NSLock()
    private let context: CloudProviderSessionContext
    private let sessionID = UUID().uuidString.lowercased()
    private var pendingCalls: [PendingCall] = []
    private var pendingModelParts: [[String: Any]] = []
    private var decodeTask: Task<Void, Never>?
    private var closed = false

    package init(context: CloudProviderSessionContext) throws {
        guard !context.targetID.rawValue.isEmpty,
              context.targetRevision > 0,
              !context.providerProfileID.isEmpty,
              context.providerProfileRevision > 0,
              !context.modelID.isEmpty,
              let projectID = context.providerProjectID,
              !projectID.isEmpty,
              context.retentionMode == .statelessRequired,
              context.retentionApprovalRevision == nil,
              context.retentionApprovalDigest == nil
        else {
            throw antigravityFailure(
                "cloud_adapter.context_invalid",
                "Antigravity session context is incomplete"
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
        let pair = LLMBackendEventStream.makeStream(
            bufferingPolicy: .bufferingOldest(32)
        )
        lock.lock()
        guard !closed, decodeTask == nil else {
            lock.unlock()
            pair.continuation.finish(throwing: antigravityFailure(
                "cloud_adapter.session_busy",
                "Antigravity session already has an active generation"
            ))
            return pair.stream
        }
        let task = Task { [weak self] in
            guard let self else {
                pair.continuation.finish(throwing: antigravityFailure(
                    "cloud_adapter.session_closed",
                    "Antigravity session was released"
                ))
                return
            }
            var decoder = AntigravityStreamDecoder()
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    for output in try decoder.consume(event) {
                        try yieldAntigravity(output, to: pair.continuation)
                    }
                }
                for output in try decoder.finish() {
                    try yieldAntigravity(output, to: pair.continuation)
                }
                self.record(
                    modelParts: decoder.modelParts,
                    calls: decoder.pendingCalls
                )
                pair.continuation.finish()
            } catch is CancellationError {
                _ = pair.continuation.yield(.cancelled)
                pair.continuation.finish()
            } catch let failure as LLMFailure {
                pair.continuation.finish(throwing: failure)
            } catch {
                pair.continuation.finish(throwing: antigravityFailure(
                    "cloud_adapter.stream_invalid",
                    "Antigravity stream could not be decoded"
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
            pendingCalls = []
            pendingModelParts = []
            return task
        }
        task?.cancel()
    }

    private func encode(
        _ turn: AuthorizedCloudGenerationTurn
    ) throws -> CloudWireRequest {
        let state = lock.withLock {
            (closed, pendingCalls, pendingModelParts)
        }
        guard !state.0 else {
            throw antigravityFailure(
                "cloud_adapter.session_closed",
                "Antigravity session is closed"
            )
        }
        try validate(turn)
        let expectedCallIDs = state.1.map(\.callID)
        let suppliedCallIDs = turn.validated.semantic.toolResults.map(\.callID)
        guard expectedCallIDs == suppliedCallIDs else {
            throw antigravityFailure(
                "cloud_adapter.tool_result_batch_mismatch",
                "Antigravity function-result batch does not match the ordered calls"
            )
        }

        let input = try antigravityInput(turn.validated.semantic.input)
        try requireEmptyHistory(
            turn.validated.semantic.providerRequiredSemanticHistory
        )
        var contents = input.contents
        if !state.2.isEmpty {
            contents.append(["role": "model", "parts": state.2])
            contents.append([
                "role": "user",
                "parts": try functionResponses(
                    turn.validated.semantic.toolResults,
                    pending: state.1
                ),
            ])
        }

        var request: [String: Any] = ["contents": contents]
        if !input.systemInstruction.isEmpty {
            request["systemInstruction"] = [
                "parts": [["text": input.systemInstruction]],
            ]
        }
        let configuration = try antigravityGenerationConfig(
            turn.validated.semantic.resolvedParameters,
            modelID: context.modelID
        )
        request["generationConfig"] = configuration
        let tools = try antigravityTools(
            turn.validated.semantic.canonicalToolSchema
        )
        if !tools.isEmpty {
            request["tools"] = [["functionDeclarations": tools]]
            request["toolConfig"] = [
                "functionCallingConfig": ["mode": "AUTO"],
            ]
        }

        return try generationRequest(
            modelID: context.modelID,
            projectID: context.providerProjectID!,
            sessionID: sessionID,
            request: request,
            provenance: .generation
        )
    }

    private func validate(
        _ turn: AuthorizedCloudGenerationTurn
    ) throws {
        guard turn.targetID == context.targetID,
              turn.targetRevision == context.targetRevision,
              turn.profileID == context.providerProfileID,
              turn.profileRevision == context.providerProfileRevision,
              turn.retentionMode == context.retentionMode,
              turn.retentionApprovalRevision
                == context.retentionApprovalRevision,
              turn.retentionApprovalDigest == context.retentionApprovalDigest,
              turn.validated.semantic.resolvedAttachments.isEmpty
        else {
            throw antigravityFailure(
                "cloud_adapter.session_mismatch",
                "authorized turn does not match the Antigravity session"
            )
        }
    }

    private func record(
        modelParts: [[String: Any]],
        calls: [PendingCall]
    ) {
        lock.withLock {
            guard !closed else { return }
            pendingModelParts = calls.isEmpty ? [] : modelParts
            pendingCalls = calls
        }
    }

    private func clearDecodeTask() {
        lock.withLock { decodeTask = nil }
    }
}

private struct AntigravityStreamDecoder {
    private(set) var modelParts: [[String: Any]] = []
    private(set) var pendingCalls: [
        AntigravityCloudCodeSession.PendingCall
    ] = []
    private var sawData = false
    private var terminal = false

    mutating func consume(
        _ event: SSEEvent
    ) throws -> [LLMBackendEvent] {
        guard !terminal else {
            throw antigravityFailure(
                "cloud_adapter.terminal_duplicate",
                "Antigravity emitted data after its terminal event"
            )
        }
        if event.data == Data("[DONE]".utf8) {
            return try complete(reason: nil)
        }
        let root = try antigravityObject(event.data)
        if let error = root["error"] as? [String: Any] {
            throw antigravityProviderError(error)
        }
        let effective = root["response"] as? [String: Any] ?? root
        sawData = true
        var output: [LLMBackendEvent] = []
        if let candidates = effective["candidates"] as? [[String: Any]],
           let first = candidates.first {
            if let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        modelParts.append(part)
                        output.append(
                            part["thought"] as? Bool == true
                                ? .reasoningSummaryDelta(text)
                                : .textDelta(text)
                        )
                    }
                    if let function = part["functionCall"] as? [String: Any],
                       let name = function["name"] as? String,
                       !name.isEmpty {
                        let arguments = function["args"] ?? [String: Any]()
                        let argumentsJSON = try antigravityJSONString(arguments)
                        let callID = (function["id"] as? String)
                            ?? "antigravity-\(UUID().uuidString.lowercased())"
                        var recordedFunction = function
                        recordedFunction["id"] = callID
                        var recordedPart = part
                        recordedPart["functionCall"] = recordedFunction
                        modelParts.append(recordedPart)
                        pendingCalls.append(.init(
                            callID: callID,
                            name: name
                        ))
                        output.append(.toolCallStarted(
                            callID: callID,
                            name: name
                        ))
                        output.append(.toolCallArgumentsDelta(
                            callID: callID,
                            delta: argumentsJSON
                        ))
                        output.append(.toolCallCompleted(.init(
                            callID: callID,
                            name: name,
                            argumentsJSON: argumentsJSON
                        )))
                    }
                }
            }
            if let usage = antigravityUsage(effective) {
                output.append(.usageUpdated(usage))
            }
            if let reason = first["finishReason"] as? String {
                output.append(contentsOf: try complete(reason: reason))
            }
        } else if let usage = antigravityUsage(effective) {
            output.append(.usageUpdated(usage))
        }
        return output
    }

    mutating func finish() throws -> [LLMBackendEvent] {
        if terminal { return [] }
        guard sawData else {
            throw antigravityFailure(
                "stream.interrupted",
                "Antigravity stream ended without model output"
            )
        }
        return try complete(reason: nil)
    }

    private mutating func complete(
        reason: String?
    ) throws -> [LLMBackendEvent] {
        guard !terminal else { return [] }
        terminal = true
        let callIDs = pendingCalls.map(\.callID)
        return [.generationCompleted(try .validated(
            outcome: callIDs.isEmpty ? .finalResponse : .toolCallsReady,
            orderedCallIDs: callIDs,
            finishReason: callIDs.isEmpty
                ? (reason == "MAX_TOKENS" ? .length : .stop)
                : .toolCalls
        ))]
    }
}

private func generationRequest(
    modelID: String,
    projectID: String,
    sessionID: String,
    request: [String: Any],
    provenance: CloudWireDataProvenance
) throws -> CloudWireRequest {
    var inner = request
    inner["sessionId"] = sessionID
    let body: [String: Any] = [
        "model": modelID,
        "project": projectID,
        "request": inner,
        "requestId": "agent-\(UUID().uuidString.lowercased())",
        "requestType": "agent",
        "userAgent": "antigravity",
    ]
    return try CloudWireRequest(
        method: "POST",
        path: "/v1internal:streamGenerateContent",
        queryItems: [URLQueryItem(name: "alt", value: "sse")],
        headers: antigravityHeaders(accept: "text/event-stream"),
        body: try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        dataProvenance: provenance
    )
}

private func antigravityHeaders(
    accept: String
) -> [String: String] {
    [
        "accept": accept,
        "content-type": "application/json",
        "user-agent": "antigravity/1.107.0 darwin/arm64",
        "x-client-name": "antigravity",
        "x-client-version": "1.107.0",
        "x-goog-api-client": "gl-node/18.18.2 fire/0.8.6 grpc/1.10.x",
    ]
}

private func antigravityInput(
    _ input: AgentLLMInput
) throws -> (systemInstruction: String, contents: [[String: Any]]) {
    var system: [String] = []
    var contents: [[String: Any]] = []
    for message in input.messages {
        var text = ""
        for part in message.content {
            guard case let .text(value) = part else {
                throw antigravityFailure(
                    "capability.cloud_attachment_path_unavailable",
                    "cloud attachment byte transport is unavailable"
                )
            }
            text += value
        }
        switch message.role {
        case .system:
            system.append(text)
        case .user:
            contents.append([
                "role": "user",
                "parts": [["text": text]],
            ])
        case .assistant:
            contents.append([
                "role": "model",
                "parts": [["text": text]],
            ])
        case .tool:
            throw antigravityFailure(
                "cloud_adapter.message_invalid",
                "tool messages require normalized result envelopes"
            )
        }
    }
    return (system.joined(separator: "\n\n"), contents)
}

private func requireEmptyHistory(
    _ history: CanonicalJSONValue
) throws {
    guard case let .array(values) = history, values.isEmpty else {
        throw antigravityFailure(
            "cloud_adapter.semantic_history_invalid",
            "Antigravity receives complete context instead of separate provider history"
        )
    }
}

private func functionResponses(
    _ results: [NormalizedToolResult],
    pending: [AntigravityCloudCodeSession.PendingCall]
) throws -> [[String: Any]] {
    try zip(results, pending).map { result, call in
        let value = try antigravityFoundationObject(result.result)
        return [
            "functionResponse": [
                "id": call.callID,
                "name": call.name,
                "response": ["result": value],
            ],
        ]
    }
}

private func antigravityTools(
    _ schema: CanonicalJSONValue
) throws -> [[String: Any]] {
    guard let object = try antigravityFoundationObject(schema)
        as? [String: Any],
        let values = object["tools"] as? [Any]
    else {
        return []
    }
    return try values.map { value in
        if let name = value as? String {
            return [
                "name": name,
                "parameters": ["type": "object", "properties": [:]],
            ]
        }
        guard let tool = value as? [String: Any] else {
            throw antigravityFailure(
                "cloud_adapter.tool_schema_invalid",
                "Antigravity function schema is invalid"
            )
        }
        if let function = tool["function"] as? [String: Any] {
            return function
        }
        return tool
    }
}

private func antigravityGenerationConfig(
    _ configuration: GenerationConfiguration,
    modelID: String
) throws -> [String: Any] {
    let supported = Set([
        LLMParameterID.samplingTemperature.rawValue,
        LLMParameterID.samplingTopP.rawValue,
        LLMParameterID.generationMaxOutputTokens.rawValue,
        LLMParameterID.generationStopSequences.rawValue,
        LLMParameterID.reasoningEffort.rawValue,
    ])
    guard Set(configuration.parameters.keys).isSubset(of: supported) else {
        throw antigravityFailure(
            "cloud_adapter.parameter_unsupported",
            "Antigravity received an unsupported canonical parameter"
        )
    }
    var output: [String: Any] = [:]
    if let value = configuration.value(for: .samplingTemperature) {
        output["temperature"] = try antigravityDecimal(value, range: 0...2)
    }
    if let value = configuration.value(for: .samplingTopP) {
        output["topP"] = try antigravityDecimal(value, range: 0...1)
    }
    if let value = configuration.value(for: .generationMaxOutputTokens) {
        guard case let .integer(number) = value, number > 0 else {
            throw antigravityParameterFailure()
        }
        output["maxOutputTokens"] = number
    } else {
        output["maxOutputTokens"] = 16_384
    }
    if let value = configuration.value(for: .generationStopSequences) {
        guard case let .textList(items) = value, !items.isEmpty else {
            throw antigravityParameterFailure()
        }
        output["stopSequences"] = items
    }
    if let value = configuration.value(for: .reasoningEffort) {
        guard case let .text(level) = value,
              ["minimal", "low", "medium", "high"].contains(level)
        else {
            throw antigravityParameterFailure()
        }
        if !modelID.lowercased().contains("claude") {
            output["thinkingConfig"] = [
                "includeThoughts": true,
                "thinkingLevel": level,
            ]
        }
    }
    return output
}

private func antigravityObject(
    _ data: Data
) throws -> [String: Any] {
    guard data.count <= 1_024 * 1_024,
          let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    else {
        throw antigravityFailure(
            "cloud_adapter.event_invalid",
            "Antigravity streaming event JSON is invalid"
        )
    }
    return object
}

private func antigravityUsage(
    _ object: [String: Any]
) -> LLMUsage? {
    guard let usage = object["usageMetadata"] as? [String: Any] else {
        return nil
    }
    return LLMUsage(
        inputTokens: antigravityUnsigned(usage["promptTokenCount"]),
        outputTokens: antigravityUnsigned(usage["candidatesTokenCount"])
    )
}

private func antigravityProviderError(
    _ error: [String: Any]
) -> LLMFailure {
    let code = String(describing: error["code"] ?? "").lowercased()
    let diagnostics = ["provider_semantic_id": "antigravity.cloud_code"]
    if code.contains("auth") || code.contains("permission") {
        return antigravityFailure(
            "cloud_transport.unauthorized",
            "provider rejected the credential",
            redactedDiagnostics: diagnostics
        )
    }
    if code.contains("quota") || code.contains("rate") {
        return antigravityFailure(
            "cloud_transport.rate_limited",
            "provider rate limit was reached",
            retryable: true,
            recoveryAction: .retry,
            redactedDiagnostics: diagnostics
        )
    }
    return antigravityFailure(
        "cloud_adapter.provider_stream_error",
        "provider emitted an Antigravity streaming error",
        redactedDiagnostics: diagnostics
    )
}

private func antigravityFoundationObject(
    _ value: CanonicalJSONValue
) throws -> Any {
    try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(value),
        options: [.fragmentsAllowed]
    )
}

private func antigravityJSONString(
    _ value: Any
) throws -> String {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw antigravityFailure(
            "cloud_adapter.tool_arguments_invalid",
            "Antigravity function arguments are invalid"
        )
    }
    return String(decoding: try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ), as: UTF8.self)
}

private func antigravityDecimal(
    _ value: LLMParameterValue,
    range: ClosedRange<Double>
) throws -> Double {
    guard case let .decimal(number) = value,
          number.isFinite,
          range.contains(number)
    else {
        throw antigravityParameterFailure()
    }
    return number
}

private func antigravityUnsigned(
    _ value: Any?
) -> UInt64? {
    if let number = value as? UInt64 { return number }
    if let number = value as? Int, number >= 0 { return UInt64(number) }
    return (value as? NSNumber).flatMap {
        $0.int64Value >= 0 ? UInt64($0.int64Value) : nil
    }
}

private func yieldAntigravity(
    _ event: LLMBackendEvent,
    to continuation: LLMBackendEventStream.Continuation
) throws {
    switch continuation.yield(event) {
    case .enqueued:
        return
    case .dropped:
        throw antigravityFailure(
            "cloud_adapter.consumer_backpressure",
            "Antigravity consumer exceeded its bounded event buffer"
        )
    case .terminated:
        throw CancellationError()
    @unknown default:
        throw antigravityFailure(
            "cloud_adapter.consumer_backpressure",
            "Antigravity consumer state is unknown"
        )
    }
}

private func antigravityParameterFailure() -> LLMFailure {
    antigravityFailure(
        "cloud_adapter.parameter_invalid",
        "Antigravity parameter value is invalid"
    )
}

private func antigravityFailure(
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
