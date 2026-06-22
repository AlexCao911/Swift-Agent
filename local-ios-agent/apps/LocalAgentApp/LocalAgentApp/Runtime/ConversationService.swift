import LocalAgentBridge

enum ConversationService {
    static func projectSummaries(
        _ summaries: [ConversationSummaryDTO]
    ) -> [ConversationSummaryViewState] {
        summaries
            .sorted {
                if $0.lastUpdatedSequence == $1.lastUpdatedSequence {
                    return $0.sessionId < $1.sessionId
                }
                return $0.lastUpdatedSequence > $1.lastUpdatedSequence
            }
            .map {
                ConversationSummaryViewState(
                    sessionId: $0.sessionId,
                    title: $0.title,
                    activeLeafId: $0.activeLeafId,
                    lastEventId: $0.lastEventId,
                    lastUpdatedSequence: $0.lastUpdatedSequence
                )
            }
    }

    static func replayActiveBranch(
        sessionId: String,
        events: [RuntimeEventDTO],
        from state: AgentViewState
    ) -> AgentViewState {
        var nextState = AgentViewState(
            phase: .ready,
            messages: [],
            draft: UserDraftViewState(),
            currentSessionId: sessionId,
            provider: state.provider,
            conversations: state.conversations
        )

        for event in events {
            RuntimeEventReducer.apply(event, to: &nextState)
        }

        nextState.currentSessionId = sessionId
        nextState.phase = .ready
        return nextState
    }
}
