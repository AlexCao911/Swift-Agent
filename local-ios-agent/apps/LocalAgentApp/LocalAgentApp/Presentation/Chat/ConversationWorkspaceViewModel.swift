import Observation

struct ConversationWorkspaceHeaderState: Equatable, Sendable {
    var agentName: String
    var profileId: String
    var profileRevisionId: UInt64?
    var modelName: String
    var toolStatusSummary: String
    var canStartRun: Bool
    var agentRepairRoute: AppRoute?
    var modelRepairRoute: AppRoute?

    var agentRevisionLabel: String {
        if let profileRevisionId {
            "v\(profileRevisionId)"
        } else {
            "No revision"
        }
    }
}

enum ConversationWorkspaceError: Error, Equatable {
    case missingActiveAgent
}

@MainActor
@Observable
final class ConversationWorkspaceViewModel {
    func headerState(
        currentState: AgentViewState,
        activeAgent: ActiveAgentRevisionSelection?,
        activeModel: ActiveModelSummary?,
        disabledNativeToolCount: Int = 0
    ) -> ConversationWorkspaceHeaderState {
        let profileId = activeAgent?.profileId ?? currentState.selectedAgentProfileId
        let revisionId = activeAgent?.profileRevisionId ?? currentState.selectedAgentProfileRevisionId
        let modelName = activeModel?.displayName ?? "No Model"
        let modelReady = activeModel?.readiness == .ready
        let hasRunnableAgent = activeAgent != nil && revisionId != nil
        let canStartRun = hasRunnableAgent && modelReady

        return ConversationWorkspaceHeaderState(
            agentName: activeAgent?.displayName ?? "No Agent",
            profileId: profileId,
            profileRevisionId: revisionId,
            modelName: modelName,
            toolStatusSummary: disabledNativeToolCount == 0
                ? "Tools ready"
                : "\(disabledNativeToolCount) tools need setup",
            canStartRun: canStartRun,
            agentRepairRoute: hasRunnableAgent ? nil : .agents(profileId: nil),
            modelRepairRoute: modelReady ? nil : .models
        )
    }

    func runtimeStateForSend(
        currentState: AgentViewState,
        activeAgent: ActiveAgentRevisionSelection?
    ) throws -> AgentViewState {
        guard let activeAgent else {
            throw ConversationWorkspaceError.missingActiveAgent
        }

        var state = currentState
        state.selectedAgentProfileId = activeAgent.profileId
        state.selectedAgentProfileRevisionId = activeAgent.profileRevisionId
        return state
    }
}
