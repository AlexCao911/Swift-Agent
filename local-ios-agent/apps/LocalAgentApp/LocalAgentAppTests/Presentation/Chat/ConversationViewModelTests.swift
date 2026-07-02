import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Conversation view model")
@MainActor
struct ConversationViewModelTests {
    @Test("load conversations projects summaries and sections")
    func loadConversationsProjectsSummariesAndSections() async throws {
        let domain = FakeConversationDomain(summaries: [
            ConversationSummaryDTO(
                sessionId: "session_1",
                title: "First",
                activeLeafId: "leaf_1",
                lastEventId: "event_1",
                lastUpdatedSequence: 1,
                lastUpdatedAtMillis: 1_700_000_000_000,
                searchText: "first"
            ),
        ])
        let viewModel = ConversationViewModel(domain: domain)

        try await viewModel.loadConversations()

        #expect(viewModel.conversations.map(\.sessionId) == ["session_1"])
        #expect(viewModel.sections.flatMap(\.conversations).map(\.sessionId) == ["session_1"])
    }

    @Test("search query filters projected sections")
    func searchQueryFiltersProjectedSections() async throws {
        let domain = FakeConversationDomain(summaries: [
            ConversationSummaryDTO(
                sessionId: "session_1",
                title: "First",
                activeLeafId: "leaf_1",
                lastEventId: "event_1",
                lastUpdatedSequence: 1,
                searchText: "alpha"
            ),
            ConversationSummaryDTO(
                sessionId: "session_2",
                title: "Second",
                activeLeafId: "leaf_2",
                lastEventId: "event_2",
                lastUpdatedSequence: 2,
                searchText: "beta"
            ),
        ])
        let viewModel = ConversationViewModel(domain: domain)
        viewModel.searchQuery = "alpha"

        try await viewModel.loadConversations()

        #expect(viewModel.conversations.map(\.sessionId) == ["session_2", "session_1"])
        #expect(viewModel.sections.flatMap(\.conversations).map(\.sessionId) == ["session_1"])
    }
}

private struct FakeConversationDomain: ConversationDomain {
    var summaries: [ConversationSummaryDTO] = []

    func listSessions() async throws -> [ConversationSummaryDTO] {
        summaries
    }

    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        throw ConversationViewModelTestError.unimplemented
    }

    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        []
    }

    func forkSession(sessionId: String, leafId: String) async throws -> String {
        sessionId
    }

    func archiveSession(sessionId: String) async throws {}

    func renameSession(sessionId: String, title: String) async throws {}

    func deleteSession(sessionId: String) async throws {}

    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        throw ConversationViewModelTestError.unimplemented
    }
}

private enum ConversationViewModelTestError: Error {
    case unimplemented
}
