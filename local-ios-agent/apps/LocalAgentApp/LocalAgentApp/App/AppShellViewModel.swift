import Observation

@MainActor
@Observable
final class AppShellViewModel {
    var route: AppRoute
    var activeAgent: ActiveAgentRevisionSelection?
    var activeModel: ActiveModelSummary?
    var readinessBanners: [GlobalReadinessBanner]
    private(set) var returnRoute: AppRoute?
    var advancedDebugEnabled: Bool
    var showsConversationList = false
    var showsPromptDocuments = false
    private let availableAgents: [ActiveAgentRevisionSelection]
    private var pendingChatDraft: String?

    init(
        route: AppRoute = .chat(sessionId: nil),
        activeAgent: ActiveAgentRevisionSelection? = nil,
        availableAgents: [ActiveAgentRevisionSelection] = [],
        activeModel: ActiveModelSummary? = nil,
        readinessBanners: [GlobalReadinessBanner] = [],
        advancedDebugEnabled: Bool = false
    ) {
        self.route = route
        self.activeAgent = activeAgent
        self.availableAgents = availableAgents
        self.activeModel = activeModel
        self.readinessBanners = readinessBanners
        self.advancedDebugEnabled = advancedDebugEnabled
    }

    func usePublishedAgent(_ selection: PublishedAgentSelection) {
        activeAgent = ActiveAgentRevisionSelection(
            profileId: selection.profileId,
            profileRevisionId: selection.profileRevisionId,
            displayName: selection.displayName
        )
        readinessBanners.removeAll { $0.kind == .missingAgent }
    }

    @discardableResult
    func validateCanStartChat() -> Bool {
        guard activeAgent != nil else {
            upsertReadinessBanner(Self.missingAgentBanner)
            return false
        }

        readinessBanners.removeAll { $0.kind == .missingAgent }
        return true
    }

    func openBuilder(profileId: String?, revisionId: UInt64?) {
        returnRoute = route
        route = .builder(profileId: profileId, revisionId: revisionId)
    }

    func open(_ route: AppRoute) {
        self.route = route
    }

    func handleAppIntent(_ intent: AppIntentRoute) {
        switch intent.destination {
        case let .openChat(conversationId):
            if intent.startsNewChat || conversationId == nil {
                route = .chat(sessionId: Self.newConversationID())
            } else {
                route = .chat(sessionId: conversationId)
            }
            pendingChatDraft = intent.prefilledText
        case let .openBuilder(profileId):
            openBuilder(profileId: profileId, revisionId: nil)
        case let .captureText(text, targetAgentProfileId):
            pendingChatDraft = text
            guard let targetAgentProfileId else {
                openBuilder(profileId: nil, revisionId: nil)
                return
            }
            guard let target = availableAgents
                .filter({ $0.profileId == targetAgentProfileId })
                .max(by: { $0.profileRevisionId < $1.profileRevisionId })
            else {
                openBuilder(profileId: targetAgentProfileId, revisionId: nil)
                return
            }
            activeAgent = target
            readinessBanners.removeAll { $0.kind == .missingAgent }
            route = .chat(sessionId: Self.newConversationID())
        case .openConversationList:
            showsConversationList = true
        case .openPromptLibrary:
            route = .settings
            showsPromptDocuments = true
        case .openSettings:
            route = .settings
        }
    }

    func resolveChatConversationID(
        currentConversationID _: String
    ) -> String {
        guard case let .chat(sessionID) = route else {
            preconditionFailure("chat conversation can only be resolved on a chat route")
        }
        if let sessionID {
            return sessionID
        }
        let conversationID = Self.newConversationID()
        route = .chat(sessionId: conversationID)
        return conversationID
    }

    func consumePendingChatDraft() -> String? {
        defer { pendingChatDraft = nil }
        return pendingChatDraft
    }

    func openDebug(runId: String?) {
        guard advancedDebugEnabled else {
            return
        }
        route = .debug(runId: runId)
    }

    func persistenceSnapshot() -> AppShellPersistedState {
        AppShellPersistedState(
            activeProfileId: activeAgent?.profileId,
            activeProfileRevisionId: activeAgent?.profileRevisionId,
            lastRouteFamily: route.family,
            activeModelId: activeModel?.modelId
        )
    }

    private func upsertReadinessBanner(_ banner: GlobalReadinessBanner) {
        readinessBanners.removeAll { $0.id == banner.id }
        readinessBanners.append(banner)
    }

    private static let missingAgentBanner = GlobalReadinessBanner(
        id: "missing_agent",
        kind: .missingAgent,
        title: "Choose an agent",
        message: "Publish or select an agent before starting a run.",
        route: .agents(profileId: nil)
    )

    private static func newConversationID() -> String {
        "conversation-\(UUID().uuidString.lowercased())"
    }
}
