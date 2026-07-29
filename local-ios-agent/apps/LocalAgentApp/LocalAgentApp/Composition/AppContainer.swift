import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMCore
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
    let agentBuilderPublishing: (any AgentBuilderPublishing)?
    let permissionClient: any PermissionClient
    let agentBuilderToolCatalogClient: any AgentBuilderToolCatalogClient
    let runInlineCardActionHandler: RunInlineCardActionHandler
    let modelCenterClient: (any ModelCenterClient)?
    let rustRuntimeClient: RustRuntimeClient?
    let hostRunStarter: AppHostRunStarter?
    let llmHostSelections: AppLLMHostSelectionRegistry?
    let legacyMigration: LegacyLLMMigrationCoordinator?
    let readinessIssues: [String]
    let activeAgentProfile: AgentProfileDTO?
    let cloudApprovalBroker: AppCloudApprovalBroker
    let localLLMSubsystem: LocalLLMSubsystem?
    let cloudLLMSubsystem: CloudLLMSubsystem?
    let llmHostRuntime: LLMHostProductRuntime?

    func attaching(
        localLLMSubsystem: LocalLLMSubsystem,
        cloudLLMSubsystem: CloudLLMSubsystem,
        llmHostRuntime: LLMHostProductRuntime,
        modelCenterClient: any ModelCenterClient,
        agentBuilderPublishing: any AgentBuilderPublishing,
        legacyMigration: LegacyLLMMigrationCoordinator,
        readinessIssues: [String],
        activeAgentProfile: AgentProfileDTO?
    ) -> AppContainer {
        AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runtimeService: runtimeService,
            runDebugService: runDebugService,
            nativeToolkitClient: nativeToolkitClient,
            nativePermissionGateway: nativePermissionGateway,
            agentBuilderClient: agentBuilderClient,
            agentBuilderPublishing: agentBuilderPublishing,
            permissionClient: permissionClient,
            agentBuilderToolCatalogClient: agentBuilderToolCatalogClient,
            runInlineCardActionHandler: runInlineCardActionHandler,
            modelCenterClient: modelCenterClient,
            rustRuntimeClient: rustRuntimeClient,
            hostRunStarter: hostRunStarter,
            llmHostSelections: llmHostSelections,
            legacyMigration: legacyMigration,
            readinessIssues: readinessIssues,
            activeAgentProfile: activeAgentProfile,
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
    func makeOpenMinisChatViewModel(
        runtimeViewModel: AgentViewModel
    ) -> AIChatViewModel {
        AIChatViewModel(
            conversationStreamID: runtimeViewModel.state.currentSessionId
                ?? "localagent-draft"
        ) { submission in
            runtimeViewModel.state.draftText = submission.text
            runtimeViewModel.state.draft.attachments = submission.attachments
            await runtimeViewModel.send()
        }
    }

    @MainActor
    func makeOpenMinisChatStore() -> ChatStore {
        ChatStore()
    }

    @MainActor
    func makeAppShellViewModel() -> AppShellViewModel {
        AppShellViewModel(
            activeAgent: activeAgentProfile.map {
                ActiveAgentRevisionSelection(
                    profileId: $0.profileId,
                    profileRevisionId: $0.profileRevisionId,
                    displayName: $0.displayName
                )
            }
        )
    }

    @MainActor
    func makeAgentBuilderViewModel(
        profileId: String = "profile_1",
        templateId: String = "template_1"
    ) -> AgentBuilderViewModel {
        if let agentBuilderPublishing {
            AgentBuilderViewModel(
                profileId: profileId,
                templateId: templateId,
                publisher: agentBuilderPublishing,
                permissionClient: permissionClient,
                toolCatalogClient: agentBuilderToolCatalogClient
            )
        } else {
            AgentBuilderViewModel(
                profileId: profileId,
                templateId: templateId,
                builderClient: agentBuilderClient,
                permissionClient: permissionClient,
                toolCatalogClient: agentBuilderToolCatalogClient
            )
        }
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
            client: modelCenterClient,
            migration: legacyMigration,
            readinessIssues: readinessIssues
        )
    }
}
