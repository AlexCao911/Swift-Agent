import Testing
@testable import LocalAgentApp

@Suite("Conversation workspace view model")
@MainActor
struct ConversationWorkspaceViewModelTests {
    @Test("active agent revision appears in header")
    func activeAgentRevisionAppearsInHeader() {
        let viewModel = ConversationWorkspaceViewModel()

        let header = viewModel.headerState(
            currentState: AgentViewState(),
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_7",
                profileRevisionId: 12,
                displayName: "Research Agent"
            ),
            activeModel: readyModel
        )

        #expect(header.agentName == "Research Agent")
        #expect(header.profileId == "profile_7")
        #expect(header.profileRevisionId == 12)
        #expect(header.agentRevisionLabel == "v12")
        #expect(header.canStartRun == true)
    }

    @Test("runtime send state mirrors shell active agent")
    func runtimeSendStateMirrorsShellActiveAgent() throws {
        let viewModel = ConversationWorkspaceViewModel()
        let currentState = AgentViewState(
            selectedAgentProfileId: "profile_old",
            selectedAgentProfileRevisionId: 1
        )

        let sendState = try viewModel.runtimeStateForSend(
            currentState: currentState,
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_new",
                profileRevisionId: 7,
                displayName: "New Agent"
            )
        )

        #expect(sendState.selectedAgentProfileId == "profile_new")
        #expect(sendState.selectedAgentProfileRevisionId == 7)
    }

    @Test("missing active revision disables send and routes to Agents")
    func missingActiveRevisionDisablesSendAndRoutesToAgents() {
        let viewModel = ConversationWorkspaceViewModel()

        let header = viewModel.headerState(
            currentState: AgentViewState(
                selectedAgentProfileId: "profile_1",
                selectedAgentProfileRevisionId: nil
            ),
            activeAgent: nil,
            activeModel: readyModel
        )

        #expect(header.canStartRun == false)
        #expect(header.agentRepairRoute == .agents(profileId: nil))
    }

    @Test("missing model routes to Models")
    func missingModelRoutesToModels() {
        let viewModel = ConversationWorkspaceViewModel()

        let header = viewModel.headerState(
            currentState: AgentViewState(),
            activeAgent: activeAgent,
            activeModel: ActiveModelSummary(
                providerId: "cloud",
                modelId: "gpt",
                displayName: "Cloud Model",
                route: .cloud(providerId: "cloud"),
                readiness: .missingConfiguration(reason: "api_key_missing")
            )
        )

        #expect(header.canStartRun == false)
        #expect(header.modelRepairRoute == .models)
    }

    @Test("disabled native tools warn without blocking text chat")
    func disabledNativeToolsWarnWithoutBlockingTextChat() {
        let viewModel = ConversationWorkspaceViewModel()

        let header = viewModel.headerState(
            currentState: AgentViewState(),
            activeAgent: activeAgent,
            activeModel: readyModel,
            disabledNativeToolCount: 2
        )

        #expect(header.toolStatusSummary == "2 tools need setup")
        #expect(header.canStartRun == true)
    }

    @Test("missing active agent throws before send")
    func missingActiveAgentThrowsBeforeSend() {
        let viewModel = ConversationWorkspaceViewModel()

        #expect(throws: ConversationWorkspaceError.missingActiveAgent) {
            _ = try viewModel.runtimeStateForSend(
                currentState: AgentViewState(),
                activeAgent: nil
            )
        }
    }
}

private let activeAgent = ActiveAgentRevisionSelection(
    profileId: "profile_1",
    profileRevisionId: 1,
    displayName: "Assistant"
)

private let readyModel = ActiveModelSummary(
    providerId: "mock",
    modelId: "mock",
    displayName: "Mock Model",
    route: .cloud(providerId: "mock"),
    readiness: .ready
)
