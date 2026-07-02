import LocalAgentBridge
import Observation

@MainActor
@Observable
final class ConversationViewModel {
    private(set) var conversations: [ConversationSummaryViewState] = []
    private(set) var sections: [ConversationSectionViewState] = []
    var searchQuery = ""
    var draft = UserDraftViewState()
    private(set) var currentSessionId: String?

    private let domain: any ConversationDomain

    init(
        domain: any ConversationDomain,
        currentSessionId: String? = nil
    ) {
        self.domain = domain
        self.currentSessionId = currentSessionId
    }

    func loadConversations() async throws {
        let summaries = try await domain.listSessions()
        conversations = ConversationService.projectSummaries(summaries)
        sections = ConversationService.groupConversations(
            conversations,
            searchQuery: searchQuery
        )
    }
}
