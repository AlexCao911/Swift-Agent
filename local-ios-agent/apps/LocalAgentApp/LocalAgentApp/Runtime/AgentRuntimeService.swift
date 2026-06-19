import LocalAgentBridge

protocol AgentRuntimeServicing: Sendable {
    func prepare() async throws -> AgentViewState
    func sendMessage(_ text: String, state: AgentViewState) async throws -> AgentViewState
    func cancel(state: AgentViewState) async throws -> AgentViewState
}

enum AgentRuntimeServiceError: Error, Equatable, Sendable {
    case duplicateRun
    case missingPendingToolRequest(String)
}

actor AgentRuntimeService: AgentRuntimeServicing {
    private enum ActiveRun: Sendable, Equatable {
        case starting
        case running(String)
    }

    private let runtimeClient: any RuntimeClient
    private let toolDriver: MinimalHostToolDriver
    private var activeRun: ActiveRun?
    private var hasPrepared = false

    init(runtimeClient: any RuntimeClient, toolDriver: MinimalHostToolDriver) {
        self.runtimeClient = runtimeClient
        self.toolDriver = toolDriver
    }

    func prepare() async throws -> AgentViewState {
        if hasPrepared {
            let ids = try await runtimeClient.sessionIds()
            return AgentViewState(phase: .ready, currentSessionId: ids.last)
        }

        try await runtimeClient.registerToolSchema(toolDriver.schema)
        let sessionId = try await runtimeClient.createSession()
        hasPrepared = true
        return AgentViewState(phase: .ready, currentSessionId: sessionId)
    }

    func sendMessage(_ text: String, state: AgentViewState) async throws -> AgentViewState {
        guard activeRun == nil else {
            throw AgentRuntimeServiceError.duplicateRun
        }
        activeRun = .starting
        defer {
            activeRun = nil
        }

        var nextState = state
        let sessionId: String
        if let existing = state.currentSessionId {
            sessionId = existing
        } else {
            sessionId = try await runtimeClient.createSession()
            nextState.currentSessionId = sessionId
        }

        let initialTurn = try await runtimeClient.sendMessage(
            sessionId: sessionId,
            parentEventId: nil,
            text: text
        )
        activeRun = .running(initialTurn.runId)
        nextState.phase = .running(runId: initialTurn.runId)
        apply(initialTurn.events, to: &nextState)

        return try await continueToolsIfNeeded(from: initialTurn, state: nextState)
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

    private func continueToolsIfNeeded(
        from turn: AgentTurnResultDTO,
        state: AgentViewState
    ) async throws -> AgentViewState {
        var nextTurn = turn
        var nextState = state
        var continuationIndex = 0

        while nextTurn.state == .waitingTool {
            guard let pendingToolCallId = nextTurn.pendingToolCallId else {
                return nextState
            }
            let pending = try await runtimeClient.pendingToolRequests()
            guard let request = pending.first(where: { $0.runId == nextTurn.runId && $0.toolCallId == pendingToolCallId }) else {
                throw AgentRuntimeServiceError.missingPendingToolRequest(pendingToolCallId)
            }
            guard let result = try await toolDriver.execute(request, continuationIndex: continuationIndex) else {
                return nextState
            }

            nextTurn = try await runtimeClient.submitToolResult(runId: request.runId, result: result)
            apply(nextTurn.events, to: &nextState)
            continuationIndex += 1
        }

        switch nextTurn.state {
        case .completed, .cancelled:
            nextState.phase = .ready
        case .failed:
            if nextState.errorMessage == nil {
                nextState.errorMessage = "Run failed."
            }
            nextState.phase = .failed(message: nextState.errorMessage ?? "Run failed.")
        case .running, .waitingTool, .suspended:
            nextState.phase = .running(runId: nextTurn.runId)
        }
        return nextState
    }

    private func apply(_ events: [RuntimeEventDTO], to state: inout AgentViewState) {
        for event in events {
            RuntimeEventReducer.apply(event, to: &state)
        }
    }
}
