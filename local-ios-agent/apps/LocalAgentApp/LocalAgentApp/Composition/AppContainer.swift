import LocalAgentBridge
import LocalNativeToolkit

struct AppContainer {
    let runtimeService: AgentRuntimeService
    let runDebugService: RunDebugService?
    let nativeToolkitClient: any NativeToolkitClientProtocol
    let nativePermissionGateway: any NativePermissionGateway
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

    @MainActor
    func makeToolCenterViewModel() -> ToolCenterViewModel {
        ToolCenterViewModel(
            client: nativeToolkitClient,
            permissionGateway: nativePermissionGateway
        )
    }

    @MainActor
    func makeModelCenterViewModel() -> ModelCenterViewModel {
        ModelCenterViewModel(
            profiles: [
                ProviderProfileDTO(
                    id: "mock",
                    displayName: "Mock Model",
                    kind: .mock,
                    maxContextTokens: 4096
                ),
                ProviderProfileDTO(
                    id: "local_llm",
                    displayName: "Local LLM",
                    kind: .localLLM,
                    maxContextTokens: 2048
                ),
            ],
            activeModel: nil,
            localModelAvailability: ["local_llm": false],
            cloudCredentialAvailability: ["mock": true]
        )
    }
}
