import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMHost
import LocalAgentLLMLocal
import LocalNativeToolkit

struct AppContainer {
    let hostProcessEpoch: HostProcessEpoch
    let runtimeService: AgentRuntimeService
    let runDebugService: RunDebugService?
    let nativeToolkitClient: any NativeToolkitClientProtocol
    let nativePermissionGateway: any NativePermissionGateway
    let agentBuilderClient: any AgentBuilderClient
    let permissionClient: any PermissionClient
    let agentBuilderToolCatalogClient: any AgentBuilderToolCatalogClient
    let runInlineCardActionHandler: RunInlineCardActionHandler
    let modelRoutingClient: (any ModelRoutingClient)?
    let rustRuntimeClient: RustRuntimeClient?
    let hostRunStarter: AppHostRunStarter?
    let llmHostSelections: AppLLMHostSelectionRegistry?
    let cloudApprovalBroker: AppCloudApprovalBroker
    let localLLMSubsystem: LocalLLMSubsystem?
    let cloudLLMSubsystem: CloudLLMSubsystem?
    let llmHostRuntime: LLMHostProductRuntime?

    func attaching(
        localLLMSubsystem: LocalLLMSubsystem,
        cloudLLMSubsystem: CloudLLMSubsystem,
        llmHostRuntime: LLMHostProductRuntime
    ) -> AppContainer {
        AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runtimeService: runtimeService,
            runDebugService: runDebugService,
            nativeToolkitClient: nativeToolkitClient,
            nativePermissionGateway: nativePermissionGateway,
            agentBuilderClient: agentBuilderClient,
            permissionClient: permissionClient,
            agentBuilderToolCatalogClient: agentBuilderToolCatalogClient,
            runInlineCardActionHandler: runInlineCardActionHandler,
            modelRoutingClient: modelRoutingClient,
            rustRuntimeClient: rustRuntimeClient,
            hostRunStarter: hostRunStarter,
            llmHostSelections: llmHostSelections,
            cloudApprovalBroker: cloudApprovalBroker,
            localLLMSubsystem: localLLMSubsystem,
            cloudLLMSubsystem: cloudLLMSubsystem,
            llmHostRuntime: llmHostRuntime
        )
    }

    func suspendLLMHost() {
        try? llmHostRuntime?.suspend()
    }

    func resumeLLMHost() {
        try? llmHostRuntime?.resume()
    }

    func shutdownLLMHost() {
        try? llmHostRuntime?.shutdown()
    }

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
        if let modelRoutingClient {
            return ModelCenterViewModel(routingClient: modelRoutingClient)
        }

        return ModelCenterViewModel(
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
