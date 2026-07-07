import LocalAgentBridge
import LocalNativeToolkit

struct AppContainer {
    let runtimeService: AgentRuntimeService
    let nativeToolkitClient: any NativeToolkitClientProtocol
    let agentBuilderClient: any AgentBuilderClient
    let permissionClient: any PermissionClient
    let agentBuilderToolCatalogClient: any AgentBuilderToolCatalogClient

    @MainActor
    func makeAgentViewModel() -> AgentViewModel {
        AgentViewModel(service: runtimeService)
    }

    @MainActor
    func makeAppShellViewModel() -> AppShellViewModel {
        AppShellViewModel(
            activeAgent: ActiveAgentRevisionSelection(
                profileId: "profile_1",
                profileRevisionId: 1,
                displayName: "Assistant"
            )
        )
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
            permissionClient: permissionClient,
            toolCatalogClient: agentBuilderToolCatalogClient
        )
    }
}
