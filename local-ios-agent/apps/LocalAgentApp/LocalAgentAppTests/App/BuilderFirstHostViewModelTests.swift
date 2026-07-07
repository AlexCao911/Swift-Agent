import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Builder first host selection")
@MainActor
struct BuilderFirstHostViewModelTests {
    @Test("using published selection updates chat profile and revision")
    func usingPublishedSelectionUpdatesChatProfileAndRevision() {
        let viewModel = AgentViewModel(
            service: FailingAgentRuntimeService(),
            initialState: AgentViewState(
                selectedAgentProfileId: "profile_old",
                selectedAgentProfileRevisionId: 1
            )
        )
        let selection = PublishedAgentSelection(
            profileId: "profile_new",
            profileRevisionId: 7,
            displayName: "Research Agent"
        )

        BuilderFirstHostSelection.apply(selection, to: viewModel)

        #expect(viewModel.state.selectedAgentProfileId == "profile_new")
        #expect(viewModel.state.selectedAgentProfileRevisionId == 7)
    }
}

private struct FailingAgentRuntimeService: AgentRuntimeServicing {
    func prepare() async throws -> AgentViewState {
        AgentViewState()
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        state
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}
