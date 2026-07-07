import Testing
@testable import LocalAgentApp

@Suite("App shell view model")
@MainActor
struct AppShellViewModelTests {
    @Test("default route is Chat")
    func defaultRouteIsChat() {
        let viewModel = AppShellViewModel()

        #expect(viewModel.route == .chat(sessionId: nil))
        #expect(viewModel.activeAgent == nil)
    }

    @Test("published builder selection becomes active agent")
    func publishedBuilderSelectionBecomesActiveAgent() {
        let viewModel = AppShellViewModel()
        let selection = PublishedAgentSelection(
            profileId: "profile_7",
            profileRevisionId: 4,
            displayName: "Calendar Agent"
        )

        viewModel.usePublishedAgent(selection)

        #expect(viewModel.activeAgent == ActiveAgentRevisionSelection(
            profileId: "profile_7",
            profileRevisionId: 4,
            displayName: "Calendar Agent"
        ))
    }

    @Test("starting chat without active agent creates readiness banner")
    func startingChatWithoutActiveAgentCreatesReadinessBanner() {
        let viewModel = AppShellViewModel()

        let canStart = viewModel.validateCanStartChat()

        #expect(canStart == false)
        #expect(viewModel.readinessBanners == [
            GlobalReadinessBanner(
                id: "missing_agent",
                kind: .missingAgent,
                title: "Choose an agent",
                message: "Publish or select an agent before starting a run.",
                route: .agents(profileId: nil)
            ),
        ])
    }

    @Test("opening Builder from Chat preserves return route")
    func openingBuilderFromChatPreservesReturnRoute() {
        let viewModel = AppShellViewModel(route: .chat(sessionId: "session_1"))

        viewModel.openBuilder(profileId: "profile_1", revisionId: 3)

        #expect(viewModel.route == .builder(profileId: "profile_1", revisionId: 3))
        #expect(viewModel.returnRoute == .chat(sessionId: "session_1"))
    }

    @Test("opening Builder does not mutate active agent")
    func openingBuilderDoesNotMutateActiveAgent() {
        let viewModel = AppShellViewModel(
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_old",
                profileRevisionId: 1,
                displayName: "Old Agent"
            )
        )

        viewModel.openBuilder(profileId: "profile_new", revisionId: nil)

        #expect(viewModel.activeAgent == ActiveAgentRevisionSelection(
            profileId: "profile_old",
            profileRevisionId: 1,
            displayName: "Old Agent"
        ))
    }

    @Test("persistence snapshot stores only durable shell selection")
    func persistenceSnapshotStoresOnlyDurableShellSelection() {
        let viewModel = AppShellViewModel(
            route: .tools(focusedToolName: "web.fetch_url_text"),
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_1",
                profileRevisionId: 9,
                displayName: "Research Agent"
            ),
            activeModel: ActiveModelSummary(
                providerId: "local_llm",
                modelId: "model_1",
                displayName: "Local Model",
                route: .localCpp(engineId: "llama_cpp"),
                readiness: .ready
            )
        )

        #expect(viewModel.persistenceSnapshot() == AppShellPersistedState(
            activeProfileId: "profile_1",
            activeProfileRevisionId: 9,
            lastRouteFamily: .tools,
            activeModelId: "model_1"
        ))
    }

    @Test("tools route preserves focused tool name")
    func toolsRoutePreservesFocusedToolName() {
        let viewModel = AppShellViewModel()

        viewModel.open(.tools(focusedToolName: "web.fetch_url_text"))

        #expect(viewModel.route == .tools(focusedToolName: "web.fetch_url_text"))
    }

    @Test("debug route is guarded by advanced mode")
    func debugRouteIsGuardedByAdvancedMode() {
        let viewModel = AppShellViewModel(route: .settings)

        viewModel.openDebug(runId: "run_1")

        #expect(viewModel.route == .settings)

        viewModel.advancedDebugEnabled = true
        viewModel.openDebug(runId: "run_1")

        #expect(viewModel.route == .debug(runId: "run_1"))
    }

    @Test("builder route does not publish active agent")
    func builderRouteDoesNotPublishActiveAgent() {
        let viewModel = AppShellViewModel(activeAgent: nil)

        viewModel.openBuilder(profileId: "profile_1", revisionId: 2)

        #expect(viewModel.route == .builder(profileId: "profile_1", revisionId: 2))
        #expect(viewModel.activeAgent == nil)
    }
}
