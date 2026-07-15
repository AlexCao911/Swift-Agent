import LocalAgentLLMContracts

package enum LocalGenerationTerminal: Sendable {
    case completed(LLMGenerationOutcome)
    case cancelled
    case failed
}

public struct LLMBackendEventSequence: AsyncSequence, Sendable {
    public typealias Element = LLMBackendEvent

    private let state: LocalBackendEventIteratorState

    package init(
        native: CppTokenEventSequence,
        toolCallCodecID: String?,
        terminal: @escaping @Sendable (LocalGenerationTerminal) async throws -> Void
    ) {
        state = LocalBackendEventIteratorState(
            native: native,
            toolCallCodecID: toolCallCodecID,
            terminal: terminal
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let state: LocalBackendEventIteratorState

        fileprivate init(state: LocalBackendEventIteratorState) {
            self.state = state
        }

        public mutating func next() async throws -> LLMBackendEvent? {
            try await state.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: state)
    }
}

private actor LocalBackendEventIteratorState {
    private var native: CppTokenEventSequence.AsyncIterator
    private let toolCallCodecID: String?
    private let terminal: @Sendable (LocalGenerationTerminal) async throws -> Void
    private var pending: [LLMBackendEvent] = []
    private var accumulatedText = ""
    private var ended = false

    init(
        native: CppTokenEventSequence,
        toolCallCodecID: String?,
        terminal: @escaping @Sendable (LocalGenerationTerminal) async throws -> Void
    ) {
        self.native = native.makeAsyncIterator()
        self.toolCallCodecID = toolCallCodecID
        self.terminal = terminal
    }

    func next() async throws -> LLMBackendEvent? {
        if !pending.isEmpty { return pending.removeFirst() }
        guard !ended else { return nil }

        do {
            while let event = try await native.next() {
                switch event {
                case let .textDelta(text):
                    if toolCallCodecID == nil {
                        return .textDelta(text)
                    }
                    accumulatedText += text
                case let .usage(inputTokens, outputTokens):
                    return .usageUpdated(LLMUsage(
                        inputTokens: inputTokens,
                        outputTokens: outputTokens
                    ))
                case let .completed(rawFinishReason):
                    try await complete(rawFinishReason: rawFinishReason)
                    return pending.isEmpty ? nil : pending.removeFirst()
                }
            }
            guard ended else {
                ended = true
                try await terminal(.failed)
                throw LLMFailure(
                    code: "local_engine.stream_ended_without_terminal",
                    message: "local generation ended without a terminal event",
                    retryable: true
                )
            }
            return nil
        } catch is CancellationError {
            guard !ended else { return nil }
            ended = true
            try await terminal(.cancelled)
            return .cancelled
        } catch {
            if !ended {
                ended = true
                try? await terminal(.failed)
            }
            throw error
        }
    }

    private func complete(rawFinishReason: String) async throws {
        let finishReason = LLMFinishReason(rawValue: rawFinishReason) ?? .other
        if let codecID = toolCallCodecID,
           accumulatedText.contains("<tool_calls>")
        {
            let decoded = try LocalToolCallCodec.decode(
                codecID: codecID,
                rawText: accumulatedText
            )
            if !decoded.visiblePreamble.isEmpty {
                pending.append(.textDelta(decoded.visiblePreamble))
            }
            for call in decoded.calls {
                pending.append(.toolCallStarted(callID: call.callID, name: call.name))
                pending.append(.toolCallCompleted(call))
            }
            pending.append(.generationCompleted(decoded.completion))
            ended = true
            try await terminal(.completed(.toolCallsReady))
            return
        }

        if toolCallCodecID != nil, !accumulatedText.isEmpty {
            pending.append(.textDelta(accumulatedText))
        }
        pending.append(.generationCompleted(LLMBackendCompletion(
            outcome: .finalResponse,
            orderedCallIDs: [],
            finishReason: finishReason
        )))
        ended = true
        try await terminal(.completed(.finalResponse))
    }
}
