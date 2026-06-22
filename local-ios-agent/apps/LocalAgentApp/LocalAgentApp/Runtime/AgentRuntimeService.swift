import LocalAgentBridge

protocol AgentRuntimeServicing: Sendable {
    func prepare() async throws -> AgentViewState
    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState
    func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState
    func cancel(state: AgentViewState) async throws -> AgentViewState
    func newChat(state: AgentViewState) async throws -> AgentViewState
    func loadConversations(state: AgentViewState) async throws -> AgentViewState
    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState
}

extension AgentRuntimeServicing {
    func sendMessage(_ text: String, state: AgentViewState) async throws -> AgentViewState {
        try await sendMessage(text, state: state, onEvent: { _ in })
    }

    func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func newChat(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func loadConversations(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

enum AgentRuntimeServiceError: Error, Equatable, Sendable {
    case duplicateRun
    case missingPendingToolRequest(String)
}

private enum StreamBufferInput: Sendable {
    case event(RuntimeEventDTO)
    case flushTick
    case finished
}

actor AgentRuntimeService: AgentRuntimeServicing {
    private enum ActiveRun: Sendable, Equatable {
        case starting
        case running(String)
    }

    private let runtimeClient: any RuntimeClient
    private let toolDriver: MinimalHostToolDriver
    private let streamFlushNanoseconds: UInt64
    private var activeRun: ActiveRun?
    private var hasPrepared = false

    init(
        runtimeClient: any RuntimeClient,
        toolDriver: MinimalHostToolDriver,
        streamFlushNanoseconds: UInt64 = 50_000_000
    ) {
        self.runtimeClient = runtimeClient
        self.toolDriver = toolDriver
        self.streamFlushNanoseconds = streamFlushNanoseconds
    }

    func prepare() async throws -> AgentViewState {
        if hasPrepared {
            let ids = try await runtimeClient.sessionIds()
            var state = AgentViewState(phase: .ready, currentSessionId: ids.last)
            try await loadProviderState(into: &state)
            return try await loadConversations(state: state)
        }

        try await runtimeClient.registerToolSchema(toolDriver.schema)
        let sessionId = try await runtimeClient.createSession()
        hasPrepared = true
        var state = AgentViewState(phase: .ready, currentSessionId: sessionId)
        try await loadProviderState(into: &state)
        return try await loadConversations(state: state)
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        guard activeRun == nil else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        activeRun = .starting
        defer {
            activeRun = nil
        }

        var nextState = state
        let parentEventId = state.draft.targetParentEventId
        let sessionId: String
        if let existing = state.currentSessionId {
            sessionId = existing
        } else {
            sessionId = try await runtimeClient.createSession()
            nextState.currentSessionId = sessionId
        }

        if let streamingClient = runtimeClient as? any StreamingRuntimeClient {
            let stream = streamingClient.sendMessageStream(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: text
            )
            var streamedEventIds = Set<String>()
            let initialTurn = try await consume(
                stream,
                state: &nextState,
                streamedEventIds: &streamedEventIds,
                onEvent: onEvent
            )
            activeRun = .running(initialTurn.runId)
            nextState.phase = .running(runId: initialTurn.runId)
            nextState.draft.targetParentEventId = nil
            apply(initialTurn.events, to: &nextState, skipping: streamedEventIds)

            return try await continueToolsIfNeeded(
                from: initialTurn,
                state: nextState,
                streamedEventIds: streamedEventIds,
                onEvent: onEvent
            )
        }

        let initialTurn = try await runtimeClient.sendMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text
        )
        activeRun = .running(initialTurn.runId)
        nextState.phase = .running(runId: initialTurn.runId)
        nextState.draft.targetParentEventId = nil
        apply(initialTurn.events, to: &nextState)

        return try await continueToolsIfNeeded(
            from: initialTurn,
            state: nextState,
            streamedEventIds: [],
            onEvent: onEvent
        )
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        guard case .running(let activeRunId) = activeRun else {
            return state
        }
        defer {
            activeRun = nil
        }

        let event = try await runtimeClient.cancel(runId: activeRunId)
        var nextState = state
        RuntimeEventReducer.apply(event, to: &nextState)
        return nextState
    }

    func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let providerClient = runtimeClient as? any ProviderControllingRuntimeClient else {
            return state
        }

        var nextState = state
        let sessionId: String
        if let currentSessionId = nextState.currentSessionId {
            sessionId = currentSessionId
        } else {
            sessionId = try await runtimeClient.createSession()
            nextState.currentSessionId = sessionId
        }

        let event = try await providerClient.setProvider(
            sessionId: sessionId,
            providerId: providerId
        )
        RuntimeEventReducer.apply(event, to: &nextState)
        try await loadProviderState(into: &nextState)
        return nextState
    }

    func newChat(state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }

        let sessionId = try await runtimeClient.createSession()
        var nextState = AgentViewState(phase: .ready, currentSessionId: sessionId)
        try await loadProviderState(into: &nextState)
        return try await loadConversations(state: nextState)
    }

    func loadConversations(state: AgentViewState) async throws -> AgentViewState {
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        var nextState = state
        let summaries = try await conversationClient.conversationSummaries()
        nextState.conversations.conversations = ConversationService.projectSummaries(summaries)
        nextState.conversations.errorMessage = nil
        return nextState
    }

    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        let events = try await conversationClient.activeBranch(sessionId: sessionId, leafId: nil)
        var nextState = ConversationService.replayActiveBranch(
            sessionId: sessionId,
            events: events,
            from: state
        )
        try await loadProviderState(into: &nextState)
        return nextState
    }

    private func continueToolsIfNeeded(
        from turn: AgentTurnResultDTO,
        state: AgentViewState,
        streamedEventIds: Set<String>,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        var nextTurn = turn
        var nextState = state
        var streamedEventIds = streamedEventIds
        var continuationIndex = 0

        while nextTurn.state == .waitingTool {
            guard let pendingToolCallId = nextTurn.pendingToolCallId else {
                return nextState
            }
            let pending = try await runtimeClient.pendingToolRequests()
            guard let request = pending.first(where: { $0.runId == nextTurn.runId && $0.toolCallId == pendingToolCallId }) else {
                throw AgentRuntimeServiceError.missingPendingToolRequest(pendingToolCallId)
            }
            guard let result = await toolDriver.execute(request, continuationIndex: continuationIndex) else {
                return nextState
            }

            if let streamingClient = runtimeClient as? any StreamingRuntimeClient {
                let stream = streamingClient.submitToolResultStream(
                    runId: request.runId,
                    result: result
                )
                nextTurn = try await consume(
                    stream,
                    state: &nextState,
                    streamedEventIds: &streamedEventIds,
                    onEvent: onEvent
                )
                apply(nextTurn.events, to: &nextState, skipping: streamedEventIds)
            } else {
                nextTurn = try await runtimeClient.submitToolResult(runId: request.runId, result: result)
                apply(nextTurn.events, to: &nextState)
            }
            continuationIndex += 1
        }

        switch nextTurn.state {
        case .completed:
            nextState.lastTerminalReason = .completed
            nextState.finishStreamingMessages(as: .idle)
            nextState.phase = .ready
        case .cancelled:
            nextState.lastTerminalReason = .cancelled
            nextState.finishStreamingMessages(as: .cancelled)
            nextState.phase = .ready
        case .failed:
            let message = nextState.errorMessage ?? "Run failed."
            nextState.errorMessage = message
            nextState.lastTerminalReason = .failed(message)
            nextState.finishStreamingMessages(as: .failed(message))
            nextState.phase = .failed(message: message)
        case .running, .waitingTool, .suspended:
            nextState.phase = .running(runId: nextTurn.runId)
        }
        return nextState
    }

    private func consume(
        _ stream: AgentTurnStreamDTO,
        state: inout AgentViewState,
        streamedEventIds: inout Set<String>,
        onEvent: @Sendable (RuntimeEventDTO) async -> Void
    ) async throws -> AgentTurnResultDTO {
        var buffer = RuntimeStreamBuffer()
        let (inputs, continuation) = AsyncThrowingStream.makeStream(
            of: StreamBufferInput.self,
            throwing: Error.self
        )
        let events = stream.events
        let producer = Task {
            do {
                for try await event in events {
                    continuation.yield(.event(event))
                }
                continuation.yield(.finished)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        var flushTask: Task<Void, Never>?

        func updateScheduledFlush() {
            guard buffer.hasPendingEvents else {
                flushTask?.cancel()
                flushTask = nil
                return
            }

            flushTask?.cancel()
            let delay = streamFlushNanoseconds
            flushTask = Task {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return
                }
                continuation.yield(.flushTick)
            }
        }

        defer {
            producer.cancel()
            flushTask?.cancel()
        }

        do {
            inputLoop: for try await input in inputs {
                switch input {
                case .event(let event):
                    streamedEventIds.insert(event.id)
                    let events = buffer.append(event)
                    for bufferedEvent in events {
                        applyStreamedEvent(
                            bufferedEvent,
                            to: &state,
                            streamedEventIds: &streamedEventIds
                        )
                        await onEvent(bufferedEvent)
                    }
                    updateScheduledFlush()
                case .flushTick:
                    await flushStreamBuffer(
                        &buffer,
                        to: &state,
                        streamedEventIds: &streamedEventIds,
                        onEvent: onEvent
                    )
                    updateScheduledFlush()
                case .finished:
                    await flushStreamBuffer(
                        &buffer,
                        to: &state,
                        streamedEventIds: &streamedEventIds,
                        onEvent: onEvent
                    )
                    break inputLoop
                }
            }
        } catch {
            await flushStreamBuffer(
                &buffer,
                to: &state,
                streamedEventIds: &streamedEventIds,
                onEvent: onEvent
            )
            throw error
        }

        await flushStreamBuffer(
            &buffer,
            to: &state,
            streamedEventIds: &streamedEventIds,
            onEvent: onEvent
        )
        return try await stream.result.value
    }

    private func flushStreamBuffer(
        _ buffer: inout RuntimeStreamBuffer,
        to state: inout AgentViewState,
        streamedEventIds: inout Set<String>,
        onEvent: @Sendable (RuntimeEventDTO) async -> Void
    ) async {
        for bufferedEvent in buffer.flush() {
            applyStreamedEvent(
                bufferedEvent,
                to: &state,
                streamedEventIds: &streamedEventIds
            )
            await onEvent(bufferedEvent)
        }
    }

    private func applyStreamedEvent(
        _ event: RuntimeEventDTO,
        to state: inout AgentViewState,
        streamedEventIds: inout Set<String>
    ) {
        if let runId = event.runId {
            activeRun = .running(runId)
            state.phase = .running(runId: runId)
        }
        RuntimeEventReducer.apply(event, to: &state)
        streamedEventIds.insert(event.id)
    }

    private func apply(_ events: [RuntimeEventDTO], to state: inout AgentViewState) {
        for event in events {
            RuntimeEventReducer.apply(event, to: &state)
        }
    }

    private func apply(
        _ events: [RuntimeEventDTO],
        to state: inout AgentViewState,
        skipping streamedEventIds: Set<String>
    ) {
        for event in events where !streamedEventIds.contains(event.id) {
            RuntimeEventReducer.apply(event, to: &state)
        }
    }

    private func loadProviderState(into state: inout AgentViewState) async throws {
        guard let providerClient = runtimeClient as? any ProviderControllingRuntimeClient else {
            return
        }
        state.provider.profiles = try await providerClient.providerProfiles()
        state.provider.active = try await providerClient.activeProvider()
        state.provider.errorMessage = nil
    }
}
