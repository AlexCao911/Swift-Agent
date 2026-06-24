import Foundation
import LocalAgentBridge

enum ConversationService {
    static func groupConversations(
        _ conversations: [ConversationSummaryViewState],
        searchQuery: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ConversationSectionViewState] {
        let filteredConversations = filtered(conversations, by: searchQuery)
        var sections: [ConversationSectionViewState] = []

        for conversation in filteredConversations {
            let title = sectionTitle(
                for: conversation.lastMessageDate,
                now: now,
                calendar: calendar
            )
            if let index = sections.firstIndex(where: { $0.title == title }) {
                sections[index].conversations.append(conversation)
            } else {
                sections.append(
                    ConversationSectionViewState(
                        id: title,
                        title: title,
                        conversations: [conversation]
                    )
                )
            }
        }

        return sections
    }

    static func projectSummaries(
        _ summaries: [ConversationSummaryDTO]
    ) -> [ConversationSummaryViewState] {
        summaries
            .sorted {
                let leftMillis = $0.lastUpdatedAtMillis ?? 0
                let rightMillis = $1.lastUpdatedAtMillis ?? 0
                if leftMillis != rightMillis {
                    return leftMillis > rightMillis
                }
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
                    lastUpdatedSequence: $0.lastUpdatedSequence,
                    lastMessageDate: date(fromMillis: $0.lastUpdatedAtMillis),
                    searchText: $0.searchText ?? ""
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
            conversations: state.conversations,
            promptLibrary: state.promptLibrary,
            modelSettings: state.modelSettings
        )

        for event in events {
            RuntimeEventReducer.apply(event, to: &nextState)
        }

        nextState.currentSessionId = sessionId
        nextState.phase = .ready
        return nextState
    }

    private static func date(fromMillis millis: UInt64?) -> Date? {
        guard let millis, millis > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    private static func filtered(
        _ conversations: [ConversationSummaryViewState],
        by query: String
    ) -> [ConversationSummaryViewState] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return conversations
        }

        return conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || conversation.sessionId.localizedCaseInsensitiveContains(query)
                || conversation.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private static func sectionTitle(
        for date: Date?,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let date else {
            return "更早"
        }

        if calendar.isDate(date, inSameDayAs: now) {
            return "今天"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨天"
        }

        if let beforeYesterday = calendar.date(byAdding: .day, value: -2, to: now),
           calendar.isDate(date, inSameDayAs: beforeYesterday)
        {
            return "前天"
        }

        if calendar.component(.yearForWeekOfYear, from: date) == calendar.component(.yearForWeekOfYear, from: now),
           calendar.component(.weekOfYear, from: date) == calendar.component(.weekOfYear, from: now)
        {
            return "本周"
        }

        if calendar.component(.year, from: date) == calendar.component(.year, from: now),
           calendar.component(.month, from: date) == calendar.component(.month, from: now)
        {
            return "本月"
        }

        let month = calendar.component(.month, from: date)
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(month)月"
        }

        let year = calendar.component(.year, from: date)
        return "\(year)年\(month)月"
    }
}
