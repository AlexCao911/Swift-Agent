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

    init(
        route: AppRoute = .chat(sessionId: nil),
        activeAgent: ActiveAgentRevisionSelection? = nil,
        activeModel: ActiveModelSummary? = nil,
        readinessBanners: [GlobalReadinessBanner] = [],
        advancedDebugEnabled: Bool = false
    ) {
        self.route = route
        self.activeAgent = activeAgent
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
}
