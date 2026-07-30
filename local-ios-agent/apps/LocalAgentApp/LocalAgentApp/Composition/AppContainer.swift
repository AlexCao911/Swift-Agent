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
    let availableAgentProfiles: [AgentProfileDTO]
    let cloudApprovalBroker: AppCloudApprovalBroker
    let localLLMSubsystem: LocalLLMSubsystem?
    let cloudLLMSubsystem: CloudLLMSubsystem?
    let llmHostRuntime: LLMHostProductRuntime?
    let modelExecutionRegistry: OpenMinisModelExecutionRegistry?
    let attachmentRepository: OpenMinisAttachmentRepository

    func attaching(
        localLLMSubsystem: LocalLLMSubsystem,
        cloudLLMSubsystem: CloudLLMSubsystem,
        llmHostRuntime: LLMHostProductRuntime,
        modelCenterClient: any ModelCenterClient,
        agentBuilderPublishing: any AgentBuilderPublishing,
        legacyMigration: LegacyLLMMigrationCoordinator,
        modelExecutionRegistry: OpenMinisModelExecutionRegistry,
        readinessIssues: [String],
        activeAgentProfile: AgentProfileDTO?,
        availableAgentProfiles: [AgentProfileDTO]
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
            availableAgentProfiles: availableAgentProfiles,
            cloudApprovalBroker: cloudApprovalBroker,
            localLLMSubsystem: localLLMSubsystem,
            cloudLLMSubsystem: cloudLLMSubsystem,
            llmHostRuntime: llmHostRuntime,
            modelExecutionRegistry: modelExecutionRegistry,
            attachmentRepository: attachmentRepository
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
            let modelPreparer = AppRustAgentModelRunPreparer(
                selections: llmHostSelections,
                local: localLLMSubsystem,
                cloud: cloudLLMSubsystem,
                registry: modelExecutionRegistry,
                attachmentResolver: attachmentRepository
            )
            let coordinator = RustAgentCoordinator(
                conversation: conversation,
                snapshots: RustAgentInputSnapshotProvider(
                    nativeToolkit: nativeToolkitClient
                ),
                models: modelPreparer,
                projections: projections
            )
            try coordinator.startProjection(
                conversationStreamID: conversationStreamID
            )
            return AIChatViewModel(
                conversationStreamID: conversationStreamID
            ) { submission in
                guard let agent = shellViewModel.activeAgent else {
                    throw RustAgentCoordinatorError(
                        message: "Choose an agent and model before sending"
                    )
                }
                let modelWindow = try await modelPreparer.modelContextWindow(
                    agentProfileID: agent.profileId,
                    agentProfileRevisionID: agent.profileRevisionId
                )
                let attachmentReferences = try await attachmentRepository
                    .ingest(
                        submission.attachments,
                        modelContextWindow: modelWindow
                    )
                _ = try await coordinator.send(
                    requestID: UUID().uuidString.lowercased(),
                    conversationStreamID: submission.conversationStreamID,
                    clientMessageID: UUID().uuidString.lowercased(),
                    text: submission.text,
                    attachments: attachmentReferences,
                    agentProfileID: agent.profileId,
                    agentProfileRevisionID: agent.profileRevisionId
                )
            } performTranscriptAction: { conversationStreamID, action in
                switch action {
                case let .retry(anchorEventID):
                    guard let agent = shellViewModel.activeAgent else {
                        throw RustAgentCoordinatorError(
                            message: "Choose an agent and model before retrying"
                        )
                    }
                    _ = try await coordinator.retry(
                        requestID: UUID().uuidString.lowercased(),
                        conversationStreamID: conversationStreamID,
                        anchorEventID: anchorEventID,
                        agentProfileID: agent.profileId,
                        agentProfileRevisionID: agent.profileRevisionId
                    )
                case let .edit(
                    targetEventID,
                    replacementText,
                    replacementAttachments
                ):
                    guard let agent = shellViewModel.activeAgent else {
                        throw RustAgentCoordinatorError(
                            message: "Choose an agent and model before editing"
                        )
                    }
                    let modelWindow = try await modelPreparer.modelContextWindow(
                        agentProfileID: agent.profileId,
                        agentProfileRevisionID: agent.profileRevisionId
                    )
                    let attachmentReferences = try await attachmentRepository
                        .ingest(
                            replacementAttachments,
                            modelContextWindow: modelWindow
                        )
                    _ = try await coordinator.edit(
                        requestID: UUID().uuidString.lowercased(),
                        conversationStreamID: conversationStreamID,
                        targetEventID: targetEventID,
                        replacementText: replacementText,
                        replacementAttachments: attachmentReferences,
                        agentProfileID: agent.profileId,
                        agentProfileRevisionID: agent.profileRevisionId
                    )
                case let .delete(targetEventID):
                    _ = try await coordinator.submit(.deleteMessage(
                        requestID: UUID().uuidString.lowercased(),
                        conversationStreamID: conversationStreamID,
                        targetEventID: targetEventID
                    ))
                case .clear:
                    _ = try await coordinator.submit(.clearConversation(
                        requestID: UUID().uuidString.lowercased(),
                        conversationStreamID: conversationStreamID
                    ))
                case let .branch(anchorEventID, newConversationStreamID):
                    _ = try await coordinator.createBranch(
                        requestID: UUID().uuidString.lowercased(),
                        conversationStreamID: conversationStreamID,
                        anchorEventID: anchorEventID,
                        newConversationStreamID: newConversationStreamID
                    )
                case .archive:
                    _ = try await coordinator.submit(.archiveConversation(
                        requestID: UUID().uuidString.lowercased(),
                        conversationStreamID: conversationStreamID
                    ))
                }
            } selectConversation: { conversationStreamID in
                try coordinator.startProjection(
                    conversationStreamID: conversationStreamID
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
            },
            availableAgents: availableAgentProfiles.map {
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
