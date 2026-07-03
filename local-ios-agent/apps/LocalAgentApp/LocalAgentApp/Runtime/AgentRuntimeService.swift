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
    func selectConversation(sessionId: String, leafId: String?, state: AgentViewState) async throws -> AgentViewState
    func archiveConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState
    func renameConversation(sessionId: String, title: String, state: AgentViewState) async throws -> AgentViewState
    func deleteConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState
    func forkConversation(sessionId: String, leafId: String, state: AgentViewState) async throws -> AgentViewState
    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState
    func editAndResend(messageId: String, text: String, state: AgentViewState) async throws -> AgentViewState
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

    func selectConversation(sessionId: String, leafId: String?, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        try await selectConversation(sessionId: sessionId, leafId: nil, state: state)
    }

    func archiveConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func renameConversation(sessionId: String, title: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func deleteConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func forkConversation(sessionId: String, leafId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func editAndResend(messageId: String, text: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

enum AgentRuntimeServiceError: Error, Equatable, Sendable {
    case duplicateRun
    case missingPendingToolRequest(String)
}

private let rootParentEventId = "__local_agent_root__"
private let legacyCompatibilityStreamingPath = "LEGACY_COMPATIBILITY_STREAMING_PATH"

private enum StreamBufferInput: Sendable {
    case event(RuntimeEventDTO)
    case flushTick
    case finished
}

private actor CoordinatorEventCollector {
    private var state: AgentViewState

    init(state: AgentViewState) {
        self.state = state
    }

    func apply(_ event: RuntimeEventDTO) {
        RuntimeEventReducer.apply(event, to: &state)
    }

    func snapshot() -> AgentViewState {
        state
    }
}

actor AgentRuntimeService: AgentRuntimeServicing {
    private enum ActiveRun: Sendable, Equatable {
        case starting
        case running(String)
    }

    private let runtimeClient: any RuntimeClient
    private let toolDriver: MinimalHostToolDriver
    private let streamFlushNanoseconds: UInt64
    private let coordinator: (any ChatInteractionCoordinating)?
    private var activeRun: ActiveRun?
    private var hasPrepared = false

    init(
        runtimeClient: any RuntimeClient,
        toolDriver: MinimalHostToolDriver,
        streamFlushNanoseconds: UInt64 = 50_000_000,
        coordinator: (any ChatInteractionCoordinating)? = nil
    ) {
        self.runtimeClient = runtimeClient
        self.toolDriver = toolDriver
        self.streamFlushNanoseconds = streamFlushNanoseconds
        self.coordinator = coordinator
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

    #if DEBUG
    func usesConversationExecutionCoordinatorForTesting() -> Bool {
        coordinator != nil
    }
    #endif

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

        if let coordinator {
            try await applyRuntimeOptions(from: state)
            let collector = CoordinatorEventCollector(state: state)
            let result = try await coordinator.sendMessage(
                text: text,
                sessionId: state.currentSessionId,
                parentEventId: state.draft.targetParentEventId,
                agentProfileId: state.selectedAgentProfileId,
                options: state.executionOptions,
                onEvent: { event in
                    await collector.apply(event)
                    await onEvent(event)
                }
            )
            var nextState = await collector.snapshot()
            nextState.draft = UserDraftViewState()
            applyCoordinatorResult(result, to: &nextState)
            return nextState
        }

        var nextState = state
        let parentEventId = state.draft.targetParentEventId
        let draftAttachments = state.draft.attachments
        let prompt = promptText(for: text, attachments: draftAttachments)
        let blobRefs = RuntimeBlobRefCodec.encodeUserMessage(text: text, attachments: draftAttachments)
        try await applyRuntimeOptions(from: state)
        let sessionId: String
        if let existing = state.currentSessionId {
            sessionId = existing
        } else {
            sessionId = try await runtimeClient.createSession()
            nextState.currentSessionId = sessionId
        }

        if let streamingClient = runtimeClient as? any StreamingBlobReferencingRuntimeClient {
            _ = legacyCompatibilityStreamingPath
            let stream = streamingClient.sendMessageStream(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: prompt,
                blobRefs: blobRefs
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
            nextState.draft = UserDraftViewState()
            apply(initialTurn.events, to: &nextState, skipping: streamedEventIds)
            reconcileDraftUserMessage(
                originalText: text,
                attachments: draftAttachments,
                events: initialTurn.events,
                in: &nextState
            )

            return try await continueToolsIfNeeded(
                from: initialTurn,
                state: nextState,
                streamedEventIds: streamedEventIds,
                onEvent: onEvent
            )
        }

        if let streamingClient = runtimeClient as? any StreamingRuntimeClient {
            _ = legacyCompatibilityStreamingPath
            let stream = streamingClient.sendMessageStream(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: prompt
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
            nextState.draft = UserDraftViewState()
            apply(initialTurn.events, to: &nextState, skipping: streamedEventIds)
            reconcileDraftUserMessage(
                originalText: text,
                attachments: draftAttachments,
                events: initialTurn.events,
                in: &nextState
            )

            return try await continueToolsIfNeeded(
                from: initialTurn,
                state: nextState,
                streamedEventIds: streamedEventIds,
                onEvent: onEvent
            )
        }

        let initialTurn: AgentTurnResultDTO
        if let blobClient = runtimeClient as? any BlobReferencingRuntimeClient {
            initialTurn = try await blobClient.sendMessage(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: prompt,
                blobRefs: blobRefs
            )
        } else {
            initialTurn = try await runtimeClient.sendMessage(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: prompt
            )
        }
        activeRun = .running(initialTurn.runId)
        nextState.phase = .running(runId: initialTurn.runId)
        nextState.draft = UserDraftViewState()
        apply(initialTurn.events, to: &nextState)
        reconcileDraftUserMessage(
            originalText: text,
            attachments: draftAttachments,
            events: initialTurn.events,
            in: &nextState
        )

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
        var nextState = AgentViewState(
            phase: .ready,
            currentSessionId: sessionId,
            promptLibrary: state.promptLibrary,
            modelSettings: state.modelSettings
        )
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

    func selectConversation(sessionId: String, leafId: String?, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        var nextState = try await replayConversation(
            sessionId: sessionId,
            leafId: leafId,
            from: state,
            using: conversationClient
        )
        try await loadProviderState(into: &nextState)
        return nextState
    }

    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        try await selectConversation(sessionId: sessionId, leafId: nil, state: state)
    }

    func archiveConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        try await conversationClient.archiveSession(sessionId: sessionId)
        var nextState = stateAfterRemovingConversation(sessionId: sessionId, from: state)
        try? await loadProviderState(into: &nextState)
        return await reloadingConversationsIfPossible(state: nextState)
    }

    func renameConversation(sessionId: String, title: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return state
        }

        try await conversationClient.renameSession(sessionId: sessionId, title: trimmedTitle)
        return try await loadConversations(state: state)
    }

    func deleteConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        try await conversationClient.deleteSession(sessionId: sessionId)
        var nextState = stateAfterRemovingConversation(sessionId: sessionId, from: state)
        try? await loadProviderState(into: &nextState)
        return await reloadingConversationsIfPossible(state: nextState)
    }

    func forkConversation(sessionId: String, leafId: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        guard let conversationClient = runtimeClient as? any ConversationRuntimeClient else {
            return state
        }

        let forkedSessionId = try await conversationClient.forkSession(
            sessionId: sessionId,
            leafId: leafId
        )
        var nextState = try await replayConversation(
            sessionId: forkedSessionId,
            leafId: nil,
            from: state,
            using: conversationClient
        )
        try await loadProviderState(into: &nextState)
        return try await loadConversations(state: nextState)
    }

    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
        guard let assistant = state.messages.first(where: { $0.id == messageId }),
              assistant.role == .assistant,
              let originalUserId = assistant.parentId,
              let originalUser = state.messages.first(where: { $0.id == originalUserId && $0.role == .user })
        else {
            return state
        }

        var nextState = state
        nextState.draft.targetParentEventId = originalUser.parentId ?? rootParentEventId
        nextState.draft.attachments = originalUser.attachments.map(AttachmentDraftViewState.init(viewState:))
        let sentState = try await sendMessage(originalUser.text, state: nextState)
        return try await replayCurrentConversationIfPossible(state: sentState)
    }

    func editAndResend(messageId: String, text: String, state: AgentViewState) async throws -> AgentViewState {
        guard let message = state.messages.first(where: { $0.id == messageId }),
              message.role == .user
        else {
            return state
        }

        var nextState = state
        nextState.draft.targetParentEventId = message.parentId
        nextState.draft.attachments = message.attachments.map(AttachmentDraftViewState.init(viewState:))
        let sentState = try await sendMessage(text, state: nextState)
        return try await replayCurrentConversationIfPossible(state: sentState)
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
        default:
            let message = "Unknown run state: \(nextTurn.state.rawValue)"
            nextState.errorMessage = message
            nextState.lastTerminalReason = .failed(message)
            nextState.finishStreamingMessages(as: .failed(message))
            nextState.phase = .failed(message: message)
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

    private func applyCoordinatorResult(_ result: ChatInteractionResult, to state: inout AgentViewState) {
        switch result.state {
        case .completed:
            state.phase = .ready
            state.lastTerminalReason = .completed
            state.finishStreamingMessages(as: .idle)
        case .cancelled:
            state.phase = .ready
            state.lastTerminalReason = .cancelled
            state.finishStreamingMessages(as: .cancelled)
        case .failed:
            let message = state.errorMessage ?? "Run failed."
            state.errorMessage = message
            state.phase = .failed(message: message)
            state.lastTerminalReason = .failed(message)
            state.finishStreamingMessages(as: .failed(message))
        case .running, .waitingTool, .suspended:
            state.phase = .running(runId: result.runId)
            state.lastTerminalReason = nil
        default:
            state.phase = .running(runId: result.runId)
            state.lastTerminalReason = nil
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

    private func applyRuntimeOptions(from state: AgentViewState) async throws {
        guard let optionsClient = runtimeClient as? any RuntimeOptionsControllingRuntimeClient else {
            return
        }

        try await optionsClient.updateRuntimeOptions(RuntimeOptionsDTO(
            systemPrompt: state.promptLibrary.renderedSystemPrompt,
            runtimePolicy: AgentPromptDefaults.runtimePolicy,
            temperature: state.modelSettings.temperature,
            topP: state.modelSettings.topP
        ))
    }

    private func stateAfterRemovingConversation(
        sessionId: String,
        from state: AgentViewState
    ) -> AgentViewState {
        var nextState = state
        nextState.conversations.conversations.removeAll { $0.sessionId == sessionId }
        if state.currentSessionId == sessionId {
            nextState.messages = []
            nextState.draft = UserDraftViewState()
            nextState.currentSessionId = nil
            nextState.phase = .ready
            nextState.errorMessage = nil
            nextState.lastTerminalReason = nil
        }
        return nextState
    }

    private func replayCurrentConversationIfPossible(state: AgentViewState) async throws -> AgentViewState {
        guard let sessionId = state.currentSessionId,
              let conversationClient = runtimeClient as? any ConversationRuntimeClient
        else {
            return state
        }

        return try await replayConversation(
            sessionId: sessionId,
            leafId: nil,
            from: state,
            using: conversationClient
        )
    }

    private func replayConversation(
        sessionId: String,
        leafId: String?,
        from state: AgentViewState,
        using conversationClient: any ConversationRuntimeClient
    ) async throws -> AgentViewState {
        let events = try await conversationClient.activeBranch(sessionId: sessionId, leafId: leafId)
        return ConversationService.replayActiveBranch(
            sessionId: sessionId,
            events: events,
            from: state
        )
    }

    private func reloadingConversationsIfPossible(state: AgentViewState) async -> AgentViewState {
        do {
            return try await loadConversations(state: state)
        } catch {
            var nextState = state
            nextState.conversations.errorMessage = error.localizedDescription
            return nextState
        }
    }

    private func promptText(
        for text: String,
        attachments: [AttachmentDraftViewState]
    ) -> String {
        var lines: [String] = []
        if !text.isEmpty {
            lines.append(text)
        }

        for attachment in attachments {
            switch attachment.kind {
            case .link:
                if let urlString = attachment.urlString {
                    lines.append("Link: \(urlString)")
                }
            case .image:
                lines.append("Image attached: \(attachment.displayName)")
            case .file:
                lines.append("File attached: \(attachment.displayName)")
                if let textContent = attachment.textContent,
                   !textContent.isEmpty
                {
                    lines.append("File contents:\n\(textContent)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func reconcileDraftUserMessage(
        originalText: String,
        attachments: [AttachmentDraftViewState],
        events: [RuntimeEventDTO],
        in state: inout AgentViewState
    ) {
        guard !attachments.isEmpty else {
            return
        }

        let visibleAttachments = attachments.map { AttachmentViewState(draft: $0) }
        for event in events where event.kind == .userMessage {
            guard let index = state.messages.firstIndex(where: { $0.id == event.id }) else {
                continue
            }
            state.messages[index].text = originalText
            state.messages[index].attachments = visibleAttachments
        }
    }
}
