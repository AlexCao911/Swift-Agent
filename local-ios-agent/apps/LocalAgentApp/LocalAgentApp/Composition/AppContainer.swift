import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMCore
import LocalAgentLLMHost
import LocalAgentLLMLocal
import LocalNativeToolkit

struct AppContainer {
    let hostProcessEpoch: HostProcessEpoch
    let runDebugService: RunDebugService?
    let hostToolDriver: any HostToolDriving
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
    let modelExecutionRegistry: OpenMinisModelExecutionRegistry?

    func attaching(
        localLLMSubsystem: LocalLLMSubsystem,
        cloudLLMSubsystem: CloudLLMSubsystem,
        llmHostRuntime: LLMHostProductRuntime,
        modelCenterClient: any ModelCenterClient,
        agentBuilderPublishing: any AgentBuilderPublishing,
        legacyMigration: LegacyLLMMigrationCoordinator,
        modelExecutionRegistry: OpenMinisModelExecutionRegistry,
        readinessIssues: [String],
        activeAgentProfile: AgentProfileDTO?
    ) -> AppContainer {
        AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runDebugService: runDebugService,
            hostToolDriver: hostToolDriver,
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
            llmHostRuntime: llmHostRuntime,
            modelExecutionRegistry: modelExecutionRegistry
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
    func makeOpenMinisChatViewModel(
        shellViewModel: AppShellViewModel,
        chatStore: ChatStore
    ) -> AIChatViewModel {
        let routedConversationID: String? = if case let .chat(sessionID) =
            shellViewModel.route {
            sessionID
        } else {
            nil
        }
        let conversationStreamID = routedConversationID
            ?? "conversation-\(UUID().uuidString.lowercased())"
        guard let rustRuntimeClient,
              let llmHostSelections,
              let localLLMSubsystem,
              let cloudLLMSubsystem,
              let modelExecutionRegistry
        else {
            return AIChatViewModel(
                conversationStreamID: conversationStreamID
            ) { _ in
                throw RustAgentCoordinatorError(
                    message: "Rust Agent runtime is unavailable"
                )
            }
        }

        do {
            let conversation = RustConversationBridgeClient(
                gateway: rustRuntimeClient,
                legacyClient: rustRuntimeClient
            )
            let persistence = try TranscriptProjectionStore(
                fileURL: try AppBootstrapper.transcriptProjectionURL()
            )
            let projections = ProjectionFeedController(
                client: conversation,
                applier: ChatStoreProjectionApplier(
                    store: chatStore,
                    persistence: persistence
                )
            )
            let coordinator = RustAgentCoordinator(
                conversation: conversation,
                snapshots: RustAgentInputSnapshotProvider(
                    nativeToolkit: nativeToolkitClient
                ),
                models: AppRustAgentModelRunPreparer(
                    selections: llmHostSelections,
                    local: localLLMSubsystem,
                    cloud: cloudLLMSubsystem,
                    registry: modelExecutionRegistry
                ),
                projections: projections
            )
            try coordinator.startProjection(
                conversationStreamID: conversationStreamID
            )
            return AIChatViewModel(
                conversationStreamID: conversationStreamID
            ) { submission in
                guard submission.attachments.isEmpty else {
                    throw RustAgentCoordinatorError(
                        message: "Attachments are not connected to the Rust ReAct path yet"
                    )
                }
                guard let agent = shellViewModel.activeAgent else {
                    throw RustAgentCoordinatorError(
                        message: "Choose an agent and model before sending"
                    )
                }
                _ = try await coordinator.send(
                    requestID: UUID().uuidString.lowercased(),
                    conversationStreamID: submission.conversationStreamID,
                    clientMessageID: UUID().uuidString.lowercased(),
                    text: submission.text,
                    attachments: [],
                    agentProfileID: agent.profileId,
                    agentProfileRevisionID: agent.profileRevisionId
                )
            }
        } catch {
            return AIChatViewModel(
                conversationStreamID: conversationStreamID
            ) { _ in
                throw error
            }
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
