import LocalAgentLLMContracts

package struct ModelRuntimeCommandHandler: Sendable {
    private let executor: any ModelGenerationExecuting

    package init(executor: any ModelGenerationExecuting) {
        self.executor = executor
    }

    package func generate(
        request: HostModelRequest,
        generationTurnID: String,
        sequencer: LLMEventSequencer
    ) async {
        let calls = ModelToolCallCollector()
        do {
            _ = try await sequencer.submit(
                kind: .generationStarted,
                payload: LLMEventPayload(),
                generationTurnID: generationTurnID
            )
            try await executor.generate(request) { event in
                try await submit(
                    event,
                    calls: calls,
                    generationTurnID: generationTurnID,
                    sequencer: sequencer
                )
            }
            let completedCalls = await calls.completedCalls()
            for call in completedCalls {
                _ = try await sequencer.submit(
                    kind: .toolCallCompleted,
                    payload: LLMEventPayload(
                        callID: call.callID,
                        name: call.toolName,
                        argumentsJSON: call.argumentsJSON
                    ),
                    generationTurnID: generationTurnID
                )
            }
            _ = try await sequencer.submit(
                kind: .generationCompleted,
                payload: LLMEventPayload(completion: LLMBackendCompletionWire(
                    outcome: completedCalls.isEmpty
                        ? "final_response"
                        : "tool_calls_ready",
                    orderedCallIDs: completedCalls.map(\.callID),
                    finishReason: completedCalls.isEmpty ? "stop" : "tool_calls"
                )),
                generationTurnID: generationTurnID
            )
        } catch is CancellationError {
            return
        } catch {
            _ = try? await sequencer.submit(
                kind: .failed,
                payload: LLMEventPayload(failureCode: stableFailureCode(error)),
                generationTurnID: generationTurnID
            )
        }
    }

    package func cancel(runID: String) async {
        await executor.cancel(runID: runID)
    }

    package func finish(runID: String) async {
        await executor.finish(runID: runID)
    }
}

private struct CompletedModelToolCall: Sendable {
    let callID: String
    let toolName: String
    let argumentsJSON: String
}

private actor ModelToolCallCollector {
    private var order: [String] = []
    private var names: [String: String] = [:]
    private var arguments: [String: String] = [:]

    func append(
        callID: String,
        toolName: String,
        argumentsFragment: String
    ) -> Bool {
        let isNew = names[callID] == nil
        if isNew {
            order.append(callID)
            names[callID] = toolName
        }
        arguments[callID, default: ""] += argumentsFragment
        return isNew
    }

    func completedCalls() -> [CompletedModelToolCall] {
        order.map {
            CompletedModelToolCall(
                callID: $0,
                toolName: names[$0] ?? "",
                argumentsJSON: arguments[$0] ?? ""
            )
        }
    }
}

private func submit(
    _ event: HostModelEvent,
    calls: ModelToolCallCollector,
    generationTurnID: String,
    sequencer: LLMEventSequencer
) async throws {
    switch event {
    case let .textDelta(text):
        _ = try await sequencer.submit(
            kind: .textDelta,
            payload: LLMEventPayload(text: text),
            generationTurnID: generationTurnID
        )
    case let .reasoningDelta(text):
        _ = try await sequencer.submit(
            kind: .reasoningSummaryDelta,
            payload: LLMEventPayload(text: text),
            generationTurnID: generationTurnID
        )
    case let .toolCallDelta(callID, toolName, argumentsFragment):
        if await calls.append(
            callID: callID,
            toolName: toolName,
            argumentsFragment: argumentsFragment
        ) {
            _ = try await sequencer.submit(
                kind: .toolCallStarted,
                payload: LLMEventPayload(callID: callID, name: toolName),
                generationTurnID: generationTurnID
            )
        }
        _ = try await sequencer.submit(
            kind: .toolCallArgumentsDelta,
            payload: LLMEventPayload(
                callID: callID,
                name: toolName,
                argumentsJSON: argumentsFragment
            ),
            generationTurnID: generationTurnID
        )
    case let .usage(usage):
        _ = try await sequencer.submit(
            kind: .usageUpdated,
            payload: LLMEventPayload(
                inputTokens: tokenCount(usage.objectValue(forKey: "input_tokens")),
                outputTokens: tokenCount(usage.objectValue(forKey: "output_tokens"))
            ),
            generationTurnID: generationTurnID
        )
    }
}

private func tokenCount(_ value: CanonicalJSONValue?) -> UInt64? {
    guard case let .number(number) = value,
          number.isFinite,
          number >= 0,
          number.rounded() == number,
          number <= Double(UInt64.max)
    else {
        return nil
    }
    return UInt64(number)
}

private func stableFailureCode(_ error: Error) -> String {
    if let failure = error as? LLMHostFailure {
        return failure.code
    }
    return "llm.generation_failed"
}
