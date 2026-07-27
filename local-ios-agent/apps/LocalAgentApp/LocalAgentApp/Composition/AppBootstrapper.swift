import Foundation
import LocalAgentBridge
import LocalAgentLLMCloud
import LocalAgentLLMCore
import LocalAgentLLMHost
import LocalAgentLLMLocal
import LocalNativeToolkit

#if canImport(EventKit) && os(iOS)
import EventKit
#endif

enum AppBootstrapper {
    static func makeReadyContainer(
        hostProcessEpoch: HostProcessEpoch,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: RustRuntimeStoreConfiguration? = nil,
        localAppSupportRoot: URL? = nil,
        remoteCatalog: Data? = nil,
        remoteCloudCatalog: Data? = nil
    ) async throws -> AppContainer {
        let container = try makeContainer(
            hostProcessEpoch: hostProcessEpoch,
            environment: environment,
            store: store
        )
        let appSupportRoot = try localAppSupportRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let llmStore = try LLMStore(fileURL: appSupportRoot.appending(
            path: "LocalAgent/LLM/llm-state.sqlite"
        ))
        let local = try await LocalLLMSubsystem.bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: hostProcessEpoch,
            remoteCatalog: remoteCatalog,
            llmStore: llmStore
        )
        let cloud = try await CloudLLMSubsystem.bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: hostProcessEpoch,
            remoteCatalog: remoteCloudCatalog,
            approvalPrompt: container.cloudApprovalBroker,
            localUnloader: AppLocalRouteUnloader(runtime: local.runtime),
            llmStore: llmStore
        )
        guard let rust = container.rustRuntimeClient,
              let starter = container.hostRunStarter
        else {
            throw LLMHostFailure(
                code: "execution.host_composition_unavailable",
                message: "production Rust host composition is unavailable"
            )
        }
        let host = try await LLMHostProductRuntime.bootstrap(
            rust: rust,
            hostProcessEpoch: hostProcessEpoch
        )
        let modelCenterClient = AppModelCenterClient(
            local: local,
            cloud: cloud,
            store: llmStore
        )
        let migration = LegacyLLMMigrationCoordinator(
            rust: RustLegacyProfileMigrationClient(gateway: rust),
            targets: modelCenterClient,
            bindingSaga: AgentHostBindingSaga(store: llmStore)
        )
        let reconciliation = try await migration.reconcilePendingActivations()
        let activeBindings = try await llmStore.activeHostBindings()
        let targets = await llmStore.targets()
        let availableTargets = try await modelCenterClient.targetOptions()
        var readinessIssues = await container.llmHostSelections?.hydrate(
            bindings: activeBindings,
            targets: targets,
            available: availableTargets
        ) ?? []
        if !reconciliation.selectionRequiredSourceDigests.isEmpty {
            readinessIssues.append("migration.target_selection_required")
        }
        if !reconciliation.bindingRequiredSourceDigests.isEmpty {
            readinessIssues.append("migration.binding_incomplete")
        }
        let profiles = try await RustExecutionBridgeClient(
            gateway: rust,
            legacyClient: rust
        ).listAgentProfiles()
        let activeAgentProfile = profiles.sorted {
            $0.profileId == $1.profileId
                ? $0.profileRevisionId > $1.profileRevisionId
                : $0.profileId < $1.profileId
        }.first
        await starter.install(host: host, local: local, cloud: cloud)
        let agentBuilderPublishing = HostBoundAgentBuilderClient(
            portable: RustPortableAgentBuilderClient(gateway: rust),
            targets: modelCenterClient,
            bindingSaga: AgentHostBindingSaga(store: llmStore)
        )
        return container.attaching(
            localLLMSubsystem: local,
            cloudLLMSubsystem: cloud,
            llmHostRuntime: host,
            modelCenterClient: modelCenterClient,
            agentBuilderPublishing: agentBuilderPublishing,
            legacyMigration: migration,
            readinessIssues: Array(Set(readinessIssues)).sorted(),
            activeAgentProfile: activeAgentProfile
        )
    }

    static func makeContainer(
        hostProcessEpoch: HostProcessEpoch,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: RustRuntimeStoreConfiguration? = nil
    ) throws -> AppContainer {
        LocalInferenceNativeLinkProbe.requireAllExports()
        let providers = simulatorProviders(environment: environment)
        let runtimeStore: RustRuntimeStoreConfiguration
        if let store {
            runtimeStore = store
        } else {
            runtimeStore = .sqlite(path: try sqliteURL().path)
        }
        let client = try makeRuntimeClient(
            environment: environment,
            providers: providers,
            store: runtimeStore,
            hostProcessEpoch: hostProcessEpoch
        )
        let executionBridge = RustExecutionBridgeClient(gateway: client, legacyClient: client)
        let conversationBridge = RustConversationBridgeClient(
            gateway: client,
            legacyClient: client
        )
        let nativeBundle = try makeNativeToolkitBundle()
        let selections = AppLLMHostSelectionRegistry()
        let hostStarter = AppHostRunStarter(selections: selections)
        let coordinator = conversationExecutionCoordinator(
            conversationBridge: conversationBridge,
            executionBridge: executionBridge,
            toolDriver: nativeBundle.toolDriver,
            hostStarter: hostStarter
        )

        return AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runtimeService: AgentRuntimeService(
                conversation: conversationBridge,
                execution: executionBridge,
                coordinator: coordinator,
                toolDriver: nativeBundle.toolDriver
            ),
            runDebugService: RunDebugService(bridge: executionBridge),
            nativeToolkitClient: nativeBundle.client,
            nativePermissionGateway: nativeBundle.permissionGateway,
            agentBuilderClient: RustAgentBuilderClient(execution: executionBridge),
            agentBuilderPublishing: nil,
            permissionClient: MockPermissionClient(issues: []),
            agentBuilderToolCatalogClient: nativeBundle.builderToolCatalogClient,
            runInlineCardActionHandler: RunInlineCardActionHandler(
                broker: nativeBundle.interactionBroker,
                approvalResponder: ExecutionBridgeToolApprovalResponder(bridge: executionBridge)
            ),
            modelCenterClient: nil,
            rustRuntimeClient: client,
            hostRunStarter: hostStarter,
            llmHostSelections: selections,
            legacyMigration: nil,
            readinessIssues: [],
            activeAgentProfile: nil,
            cloudApprovalBroker: AppCloudApprovalBroker(),
            localLLMSubsystem: nil,
            cloudLLMSubsystem: nil,
            llmHostRuntime: nil
        )
    }

    static func makeDegradedContainer(
        error: Error,
        hostProcessEpoch: HostProcessEpoch
    ) throws -> AppContainer {
        let nativeBundle = try makeNativeToolkitBundle()
        let client = MockRuntimeClient(
            sessionIds: [],
            agentProfiles: [
                AgentProfileDTO(
                    profileId: "profile_1",
                    profileRevisionId: 1,
                    displayName: "Recovery Agent"
                ),
            ],
            turnResult: degradedTurnResult()
        )
        let selections = AppLLMHostSelectionRegistry()
        let hostStarter = AppHostRunStarter(selections: selections)
        let coordinator = conversationExecutionCoordinator(
            conversationBridge: client,
            executionBridge: client,
            toolDriver: nativeBundle.toolDriver,
            hostStarter: hostStarter
        )

        return AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runtimeService: AgentRuntimeService(
                conversation: client,
                execution: client,
                coordinator: coordinator,
                toolDriver: nativeBundle.toolDriver
            ),
            runDebugService: nil,
            nativeToolkitClient: nativeBundle.client,
            nativePermissionGateway: nativeBundle.permissionGateway,
            agentBuilderClient: MockAgentBuilderClient.withReadinessIssues([
                PermissionIssueDTO(
                    code: "app.bootstrap.degraded",
                    message: "Runtime bridge entered recovery mode: \(error.localizedDescription)"
                ),
            ]),
            agentBuilderPublishing: nil,
            permissionClient: MockPermissionClient(issues: []),
            agentBuilderToolCatalogClient: nativeBundle.builderToolCatalogClient,
            runInlineCardActionHandler: RunInlineCardActionHandler(
                broker: nativeBundle.interactionBroker
            ),
            modelCenterClient: nil,
            rustRuntimeClient: nil,
            hostRunStarter: hostStarter,
            llmHostSelections: selections,
            legacyMigration: nil,
            readinessIssues: ["app.bootstrap.degraded"],
            activeAgentProfile: AgentProfileDTO(
                profileId: "profile_1",
                profileRevisionId: 1,
                displayName: "Recovery Agent"
            ),
            cloudApprovalBroker: AppCloudApprovalBroker(),
            localLLMSubsystem: nil,
            cloudLLMSubsystem: nil,
            llmHostRuntime: nil
        )
    }

    static func makeLastResortContainer(
        error: Error,
        hostProcessEpoch: HostProcessEpoch
    ) -> AppContainer {
        let permissionStore = PermissionStore()
        let client = MockRuntimeClient(turnResult: degradedTurnResult())
        let toolDriver = MinimalHostToolDriver()
        let selections = AppLLMHostSelectionRegistry()
        let hostStarter = AppHostRunStarter(selections: selections)
        let coordinator = conversationExecutionCoordinator(
            conversationBridge: client,
            executionBridge: client,
            toolDriver: toolDriver,
            hostStarter: hostStarter
        )
        return AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runtimeService: AgentRuntimeService(
                conversation: client,
                execution: client,
                coordinator: coordinator,
                toolDriver: toolDriver
            ),
            runDebugService: nil,
            nativeToolkitClient: LastResortNativeToolkitClient(error: error),
            nativePermissionGateway: StoreBackedNativePermissionGateway(store: permissionStore),
            agentBuilderClient: MockAgentBuilderClient.withReadinessIssues([
                PermissionIssueDTO(
                    code: "app.bootstrap.last_resort",
                    message: "App entered last-resort recovery mode: \(error.localizedDescription)"
                ),
            ]),
            agentBuilderPublishing: nil,
            permissionClient: MockPermissionClient(issues: []),
            agentBuilderToolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: []),
            runInlineCardActionHandler: RunInlineCardActionHandler(
                broker: NativeInteractionBroker(
                    store: InMemoryPendingUserInteractionStore(),
                    presenter: UnavailableNativeInteractionPresenter()
                )
            ),
            modelCenterClient: nil,
            rustRuntimeClient: nil,
            hostRunStarter: hostStarter,
            llmHostSelections: selections,
            legacyMigration: nil,
            readinessIssues: ["app.bootstrap.last_resort"],
            activeAgentProfile: nil,
            cloudApprovalBroker: AppCloudApprovalBroker(),
            localLLMSubsystem: nil,
            cloudLLMSubsystem: nil,
            llmHostRuntime: nil
        )
    }

    private static func makeRuntimeClient(
        environment: [String: String],
        providers: [RustRuntimeProviderConfiguration],
        store: RustRuntimeStoreConfiguration,
        hostProcessEpoch: HostProcessEpoch
    ) throws -> RustRuntimeClient {
        let requestedProviderId = runtimeProviderId(environment: environment, providers: providers)

        func client(
            for store: RustRuntimeStoreConfiguration,
            providerId: String
        ) throws -> RustRuntimeClient {
            try RustRuntimeClient(configuration: RustRuntimeConfiguration(
                systemPrompt: AgentPromptDefaults.systemPrompt,
                runtimePolicy: AgentPromptDefaults.runtimePolicy,
                providerId: providerId,
                hostProcessEpoch: hostProcessEpoch,
                store: store,
                providers: providers,
                agentOS: agentOSConfiguration()
            ))
        }

        func resilientClient(for store: RustRuntimeStoreConfiguration) throws -> RustRuntimeClient {
            do {
                return try client(for: store, providerId: requestedProviderId)
            } catch {
                guard requestedProviderId != "mock" else {
                    throw error
                }
                return try client(for: store, providerId: "mock")
            }
        }

        do {
            return try resilientClient(for: store)
        } catch {
            guard case .sqlite(let path) = store else {
                throw error
            }

            let inMemoryClient = try resilientClient(for: .inMemory)
            do {
                try recoverSQLiteStore(atPath: path)
                return try resilientClient(for: store)
            } catch {
                return inMemoryClient
            }
        }
    }

    private static func makeNativeToolkitBundle() throws -> NativeToolkitBundle {
        let permissionStore = PermissionStore()
        let eventStore: EKEventStore?
#if canImport(EventKit) && os(iOS)
        eventStore = EKEventStore()
#else
        eventStore = nil
#endif
        let nativePermissionGateway = nativePermissionGateway(
            permissionStore: permissionStore,
            eventStore: eventStore
        )
        let catalogBox = NativeCatalogBox(catalog: try NativeToolCatalog(tools: []))
        let listTools = NativeListToolsTool(catalogProvider: { catalogBox.catalog })
        let nativeCatalog = try NativeToolCatalog(tools: nativeTools(
            listTools: listTools,
            permissionStore: permissionStore,
            eventStore: eventStore
        ))
        catalogBox.catalog = nativeCatalog
        let nativeToolkitClient = NativeToolkitClient(catalog: nativeCatalog)
        let effectLedger = try HostToolEffectLedger(
            fileURL: try hostToolEffectsURL()
        )
        let toolDriver = NativeHostToolDriver(
            toolkit: nativeToolkitClient,
            effectLedger: effectLedger
        )
        let builderToolCatalogClient = NativeManifestToolCatalogClient(catalogProvider: {
            nativeCatalog
        })
        let pendingInteractionStore = try FileBackedPendingUserInteractionStore(
            directory: try pendingInteractionsURL()
        )
        let nativeInteractionBroker = NativeInteractionBroker(
            store: pendingInteractionStore,
            presenter: UnavailableNativeInteractionPresenter()
        )

        return NativeToolkitBundle(
            client: nativeToolkitClient,
            toolDriver: toolDriver,
            permissionGateway: nativePermissionGateway,
            builderToolCatalogClient: builderToolCatalogClient,
            interactionBroker: nativeInteractionBroker
        )
    }

    private static func conversationExecutionCoordinator(
        conversationBridge: any ConversationBridgeClient,
        executionBridge: any ExecutionBridgeClient,
        toolDriver: any HostToolDriving,
        hostStarter: AppHostRunStarter
    ) -> ChatInteractionCoordinator {
        let conversationDomain = ConversationDomainAdapter(bridge: conversationBridge)
        let executionDomain = ExecutionDomainAdapter(
            profiles: AgentProfileService(bridge: executionBridge),
            composition: AgentCompositionService(bridge: executionBridge),
            lifecycle: RunLifecycleService(bridge: executionBridge),
            events: RunEventStreamService(bridge: executionBridge),
            tools: ToolApprovalService(bridge: executionBridge),
            debug: RunDebugService(bridge: executionBridge),
            inference: InferenceSettingsService(bridge: executionBridge)
        )
        let coordinator = ChatInteractionCoordinator(
            conversation: conversationDomain,
            execution: executionDomain,
            toolDriver: toolDriver,
            runStarter: hostStarter
        )
        return coordinator
    }

    private static func agentOSConfiguration() -> RustAgentOSConfiguration {
        RustAgentOSConfiguration(seedDevelopmentProfile: true)
    }

    private static func nativeTools(
        listTools: NativeListToolsTool,
        permissionStore: PermissionStore,
        eventStore: EKEventStore?
    ) -> [any NativeTool] {
        var tools: [any NativeTool] = [
            listTools,
            NativePermissionStatusTool(permissionStore: permissionStore),
            WebFetchURLTextTool(),
            FilesPickDocumentTool(),
            PhotosPickImagesTool(),
        ]

        #if canImport(EventKit) && os(iOS)
        if let eventStore {
            tools.append(CalendarSearchEventsTool(calendar: EventKitCalendarAdapter(eventStore: eventStore)))
            tools.append(RemindersCreateReminderTool(reminders: EventKitReminderAdapter(eventStore: eventStore)))
        }
        #endif

        return tools
    }

    private static func nativePermissionGateway(
        permissionStore: PermissionStore,
        eventStore: EKEventStore?
    ) -> any NativePermissionGateway {
        #if canImport(EventKit) && os(iOS)
        if let eventStore {
            return EventKitPermissionAdapter(eventStore: eventStore)
        }
        #endif
        return StoreBackedNativePermissionGateway(store: permissionStore)
    }

    static func sqliteURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("LocalAgent", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("agent.sqlite")
    }

    static func pendingInteractionsURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try sqliteURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("PendingInteractions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func hostToolEffectsURL(fileManager: FileManager = .default) throws -> URL {
        try sqliteURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("host-tool-effects.sqlite")
    }

    private static func recoverSQLiteStore(
        atPath path: String,
        fileManager: FileManager = .default
    ) throws {
        let suffix = ".recovered-\(UUID().uuidString)"
        for sqliteSuffix in ["", "-wal", "-shm"] {
            let sourcePath = path + sqliteSuffix
            guard fileManager.fileExists(atPath: sourcePath) else {
                continue
            }

            let source = URL(fileURLWithPath: sourcePath)
            let destination = URL(fileURLWithPath: sourcePath + suffix)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func degradedTurnResult() -> AgentTurnResultDTO {
        AgentTurnResultDTO(
            runId: "run_degraded",
            state: .completed,
            events: [
                RuntimeEventDTO(
                    id: "entry_degraded_assistant",
                    sessionId: "session_1",
                    parentId: nil,
                    runId: "run_degraded",
                    sequence: 1,
                    depth: 0,
                    kind: .assistantMessageCompleted,
                    payload: "Runtime recovery mode is active. Mock chat is available while the local bridge restarts.",
                    blobRefs: []
                ),
            ],
            pendingToolCallId: nil
        )
    }

    static func runtimeProviderId(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        providers: [RustRuntimeProviderConfiguration]? = nil
    ) -> String {
        let configuredProviders = providers ?? simulatorProviders(environment: environment)
        if let providerId = environment["LOCAL_AGENT_DEFAULT_PROVIDER_ID"], !providerId.isEmpty {
            if configuredProviders.contains(where: { $0.bootstrapProviderId == providerId }) {
                return providerId
            }
            if providerId == "local_llm",
               let localProviderId = configuredProviders.first(where: { provider in
                   switch provider {
                   case .localLLM, .namedLocalLLM:
                       true
                   default:
                       false
                   }
               })?.bootstrapProviderId {
                return localProviderId
            }
            if providerId == "local_llm" || providerId.hasPrefix("local_llm.") {
                return "mock"
            }
            return providerId
        }

        if let localProviderId = configuredProviders.first(where: { provider in
            switch provider {
            case .localLLM, .namedLocalLLM:
                true
            default:
                false
            }
        })?.bootstrapProviderId {
            return localProviderId
        }

        return "mock"
    }

    static func simulatorProviders(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [RustRuntimeProviderConfiguration] {
        var providers: [RustRuntimeProviderConfiguration] = []

        let legacyLlamaConfig = environment["LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON"]
        let llamaConfig = environment["LOCAL_AGENT_LLAMA_CPP_MODEL_CONFIG_JSON"] ?? legacyLlamaConfig
        if let llamaConfig, localModelConfigHasExistingModelPath(llamaConfig) {
            providers.append(.namedLocalLLM(
                providerId: "local_llm.llama_cpp",
                displayName: "llama.cpp",
                model: "local.gguf.simulator",
                modelConfigJson: llamaConfig,
                maxContextTokens: 2048
            ))
        }

        if let litertConfig = environment["LOCAL_AGENT_LITERT_MODEL_CONFIG_JSON"],
           localModelConfigHasExistingModelPath(litertConfig) {
            providers.append(.namedLocalLLM(
                providerId: "local_llm.litert",
                displayName: "LiteRT",
                model: "local.litert.simulator",
                modelConfigJson: litertConfig,
                maxContextTokens: 2048
            ))
        }

        return providers
    }

    private static func localModelConfigHasExistingModelPath(_ modelConfigJson: String) -> Bool {
        guard !modelConfigJson.isEmpty,
              let data = modelConfigJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelPath = object["model_path"] as? String,
              !modelPath.isEmpty
        else {
            return false
        }
        return FileManager.default.fileExists(atPath: modelPath)
    }
}

private final class NativeCatalogBox: @unchecked Sendable {
    var catalog: NativeToolCatalog

    init(catalog: NativeToolCatalog) {
        self.catalog = catalog
    }
}

private struct NativeToolkitBundle {
    let client: NativeToolkitClient
    let toolDriver: NativeHostToolDriver
    let permissionGateway: any NativePermissionGateway
    let builderToolCatalogClient: NativeManifestToolCatalogClient
    let interactionBroker: NativeInteractionBroker
}

private struct AppLocalRouteUnloader: LocalRouteUnloading {
    let runtime: LocalModelRuntime

    func unloadForCloudRouteSwitch() async throws {
        try await runtime.unloadForRouteSwitch()
    }
}

private actor LastResortNativeToolkitClient: NativeToolkitClientProtocol {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot {
        NativeToolkitRegistrationSnapshot(schemas: [], toolNames: [])
    }

    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        ToolResultDTO(
            displayText: "Native toolkit is unavailable.",
            modelText: "Native toolkit is unavailable.",
            structuredJson: #"{"error":"native_toolkit_unavailable"}"#,
            auditText: "Native toolkit unavailable: \(error.localizedDescription)",
            sensitivity: .public,
            retention: .runOnly,
            isError: true
        )
    }
}
