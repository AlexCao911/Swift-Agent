import LocalAgentBridge

struct AppContainer {
    let runtimeService: AgentRuntimeService
    let agentBuilderClient: any AgentBuilderClient
    let permissionClient: any PermissionClient

    @MainActor
    func makeAgentViewModel() -> AgentViewModel {
        AgentViewModel(service: runtimeService)
    }

    @MainActor
    func makeAgentBuilderViewModel(
        profileId: String = "profile_1",
        templateId: String = "template_1"
    ) -> AgentBuilderViewModel {
        AgentBuilderViewModel(
            profileId: profileId,
            templateId: templateId,
            builderClient: agentBuilderClient,
            permissionClient: permissionClient
        )
    }
}
