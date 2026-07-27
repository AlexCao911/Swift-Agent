import Foundation
import LocalAgentBridge

protocol AgentRuntimeServicing: Sendable {
    func prepare() async throws -> AgentViewState
    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState
    func cancel(state: AgentViewState) async throws -> AgentViewState
    func newChat(state: AgentViewState) async throws -> AgentViewState
    func loadConversations(state: AgentViewState) async throws -> AgentViewState
    func selectConversation(
        sessionId: String,
        leafId: String?,
        state: AgentViewState
    ) async throws -> AgentViewState
    func archiveConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState
    func renameConversation(
        sessionId: String,
        title: String,
        state: AgentViewState
    ) async throws -> AgentViewState
    func deleteConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState
    func forkConversation(
        sessionId: String,
        leafId: String,
        state: AgentViewState
    ) async throws -> AgentViewState
    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState
    func editAndResend(
        messageId: String,
        text: String,
        state: AgentViewState
    ) async throws -> AgentViewState
}

extension AgentRuntimeServicing {
    func sendMessage(_ text: String, state: AgentViewState) async throws -> AgentViewState {
        try await sendMessage(text, state: state, onEvent: { _ in })
    }

    func newChat(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func loadConversations(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func selectConversation(
        sessionId: String,
        leafId: String?,
        state: AgentViewState
    ) async throws -> AgentViewState {
        state
    }

    func selectConversation(
        sessionId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try await selectConversation(sessionId: sessionId, leafId: nil, state: state)
    }

    func archiveConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func renameConversation(
        sessionId: String,
        title: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        state
    }

    func deleteConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func forkConversation(
        sessionId: String,
        leafId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        state
    }

    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func editAndResend(
        messageId: String,
        text: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        state
    }
}

enum AgentRuntimeServiceError: Error, Equatable, Sendable {
    case duplicateRun
    case missingAgentProfileRevision
}

private let rootParentEventId = "__local_agent_root__"

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

    private let conversation: any ConversationBridgeClient
    private let execution: any ExecutionBridgeClient
    private let coordinator: any ChatInteractionCoordinating
    private let toolDriver: any HostToolDriving
    private var activeRun: ActiveRun?
    private var hasPrepared = false

    init(
        conversation: any ConversationBridgeClient,
        execution: any ExecutionBridgeClient,
        coordinator: any ChatInteractionCoordinating,
        toolDriver: any HostToolDriving
    ) {
        self.conversation = conversation
        self.execution = execution
        self.coordinator = coordinator
        self.toolDriver = toolDriver
    }

    func prepare() async throws -> AgentViewState {
        if !hasPrepared {
            for schema in await toolDriver.schemas() {
                try await execution.registerToolSchema(schema)
            }
            hasPrepared = true
        }

        let summaries = try await conversation.listSessions()
        var state = AgentViewState(
            phase: .ready,
            currentSessionId: summaries.first?.sessionId
        )
        state.conversations.conversations = ConversationService.projectSummaries(summaries)
        return state
    }

    #if DEBUG
    func usesConversationExecutionCoordinatorForTesting() -> Bool {
        true
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
        guard let profileRevisionID = state.selectedAgentProfileRevisionId else {
            throw AgentRuntimeServiceError.missingAgentProfileRevision
        }

        activeRun = .starting
        defer { activeRun = nil }

        let collector = CoordinatorEventCollector(state: state)
        let result = try await coordinator.sendMessage(
            text: text,
            sessionId: state.currentSessionId,
            parentEventId: state.draft.targetParentEventId,
            agentProfileId: state.selectedAgentProfileId,
            agentProfileRevisionId: profileRevisionID,
            options: ExecutionOptionsDTO(),
            onEvent: { [weak self] event in
                if let runID = event.runId {
                    await self?.recordActiveRun(runID)
                }
                await collector.apply(event)
                await onEvent(event)
            }
        )

        var nextState = await collector.snapshot()
        nextState.draft = UserDraftViewState()
        applyCoordinatorResult(result, to: &nextState)
        await applyPendingApprovalStateIfNeeded(
            runID: result.runId,
            runState: result.state,
            to: &nextState
        )
        return nextState
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        guard case .running(let runID) = activeRun else {
            return state
        }
        let event = try await execution.cancelRun(runId: runID)
        activeRun = nil
        var nextState = state
        RuntimeEventReducer.apply(event, to: &nextState)
        return nextState
    }

    func newChat(state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }

        var nextState = AgentViewState(
            phase: .ready,
            currentSessionId: nil,
            conversations: state.conversations,
            promptLibrary: state.promptLibrary,
            selectedAgentProfileId: state.selectedAgentProfileId,
            selectedAgentProfileRevisionId: state.selectedAgentProfileRevisionId
        )
        nextState.conversations.conversations = ConversationService.projectSummaries(
            try await conversation.listSessions()
        )
        return nextState
    }

    func loadConversations(state: AgentViewState) async throws -> AgentViewState {
        var nextState = state
        nextState.conversations.conversations = ConversationService.projectSummaries(
            try await conversation.listSessions()
        )
        nextState.conversations.errorMessage = nil
        return nextState
    }

    func selectConversation(
        sessionId: String,
        leafId: String?,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try ensureIdle(state)
        return try await replayConversation(
            sessionID: sessionId,
            leafID: leafId,
            from: state
        )
    }

    func selectConversation(
        sessionId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try await selectConversation(sessionId: sessionId, leafId: nil, state: state)
    }

    func archiveConversation(
        sessionId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try ensureIdle(state)
        try await conversation.archiveSession(sessionId: sessionId)
        return try await loadConversations(
            state: stateAfterRemovingConversation(sessionID: sessionId, from: state)
        )
    }

    func renameConversation(
        sessionId: String,
        title: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try ensureIdle(state)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return state }
        try await conversation.renameSession(sessionId: sessionId, title: title)
        return try await loadConversations(state: state)
    }

    func deleteConversation(
        sessionId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try ensureIdle(state)
        try await conversation.deleteSession(sessionId: sessionId)
        return try await loadConversations(
            state: stateAfterRemovingConversation(sessionID: sessionId, from: state)
        )
    }

    func forkConversation(
        sessionId: String,
        leafId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        try ensureIdle(state)
        let forkedSessionID = try await conversation.forkSession(
            sessionId: sessionId,
            leafId: leafId
        )
        let replayed = try await replayConversation(
            sessionID: forkedSessionID,
            leafID: nil,
            from: state
        )
        return try await loadConversations(state: replayed)
    }

    func regenerate(
        from messageId: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        guard let assistant = state.messages.first(where: { $0.id == messageId }),
              assistant.role == .assistant,
              let originalUserID = assistant.parentId,
              let originalUser = state.messages.first(where: {
                  $0.id == originalUserID && $0.role == .user
              })
        else {
            return state
        }

        var nextState = state
        nextState.draft.targetParentEventId = originalUser.parentId ?? rootParentEventId
        nextState.draft.attachments = originalUser.attachments.map(
            AttachmentDraftViewState.init(viewState:)
        )
        let sent = try await sendMessage(originalUser.text, state: nextState)
        return try await replayCurrentConversationIfPossible(state: sent)
    }

    func editAndResend(
        messageId: String,
        text: String,
        state: AgentViewState
    ) async throws -> AgentViewState {
        guard let message = state.messages.first(where: { $0.id == messageId }),
              message.role == .user
        else {
            return state
        }

        var nextState = state
        nextState.draft.targetParentEventId = message.parentId
        nextState.draft.attachments = message.attachments.map(
            AttachmentDraftViewState.init(viewState:)
        )
        let sent = try await sendMessage(text, state: nextState)
        return try await replayCurrentConversationIfPossible(state: sent)
    }

    private func recordActiveRun(_ runID: String) {
        activeRun = .running(runID)
    }

    private func ensureIdle(_ state: AgentViewState) throws {
        guard activeRun == nil, !state.phase.isRunning else {
            throw AgentRuntimeServiceError.duplicateRun
        }
    }

    private func applyCoordinatorResult(
        _ result: ChatInteractionResult,
        to state: inout AgentViewState
    ) {
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

    private func applyPendingApprovalStateIfNeeded(
        runID: String,
        runState: RunStateDTO,
        to state: inout AgentViewState
    ) async {
        switch runState {
        case .suspended, .waitingTool:
            do {
                state.pendingApprovalRequest = try await execution
                    .pendingApprovalRequests()
                    .first { $0.runId == runID }
            } catch {
                state.errorMessage = error.localizedDescription
            }
        case .completed, .cancelled, .failed:
            state.pendingApprovalRequest = nil
        default:
            break
        }
    }

    private func stateAfterRemovingConversation(
        sessionID: String,
        from state: AgentViewState
    ) -> AgentViewState {
        var nextState = state
        nextState.conversations.conversations.removeAll { $0.sessionId == sessionID }
        if state.currentSessionId == sessionID {
            nextState.messages = []
            nextState.draft = UserDraftViewState()
            nextState.currentSessionId = nil
            nextState.phase = .ready
            nextState.errorMessage = nil
            nextState.lastTerminalReason = nil
        }
        return nextState
    }

    private func replayCurrentConversationIfPossible(
        state: AgentViewState
    ) async throws -> AgentViewState {
        guard let sessionID = state.currentSessionId else { return state }
        return try await replayConversation(
            sessionID: sessionID,
            leafID: nil,
            from: state
        )
    }

    private func replayConversation(
        sessionID: String,
        leafID: String?,
        from state: AgentViewState
    ) async throws -> AgentViewState {
        ConversationService.replayActiveBranch(
            sessionId: sessionID,
            events: try await conversation.activeBranch(
                sessionId: sessionID,
                leafId: leafID
            ),
            from: state
        )
    }
}
