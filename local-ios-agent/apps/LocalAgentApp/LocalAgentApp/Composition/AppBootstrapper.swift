import Foundation
import LocalAgentBridge
import LocalNativeToolkit

#if canImport(EventKit) && os(iOS)
import EventKit
#endif

enum AppBootstrapper {
    static func makeContainer(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: RustRuntimeStoreConfiguration? = nil
    ) throws -> AppContainer {
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
            store: runtimeStore
        )
        let executionBridge = RustExecutionBridgeClient(gateway: client, legacyClient: client)
        let nativeBundle = try makeNativeToolkitBundle()
        let coordinator = conversationExecutionCoordinator(
            environment: environment,
            client: client,
            executionBridge: executionBridge,
            toolDriver: nativeBundle.toolDriver
        )

        return AppContainer(
            runtimeService: AgentRuntimeService(
                runtimeClient: client,
                toolDriver: nativeBundle.toolDriver,
                coordinator: coordinator
            ),
            runDebugService: RunDebugService(bridge: executionBridge),
            nativeToolkitClient: nativeBundle.client,
            nativePermissionGateway: nativeBundle.permissionGateway,
            agentBuilderClient: RustAgentBuilderClient(execution: executionBridge),
            permissionClient: MockPermissionClient(issues: []),
            agentBuilderToolCatalogClient: nativeBundle.builderToolCatalogClient,
            runInlineCardActionHandler: RunInlineCardActionHandler(
                broker: nativeBundle.interactionBroker,
                approvalResponder: ExecutionBridgeToolApprovalResponder(bridge: executionBridge)
            ),
            modelRoutingClient: RuntimeModelRoutingClient(runtimeClient: client)
        )
    }

    static func makeDegradedContainer(error: Error) throws -> AppContainer {
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

        return AppContainer(
            runtimeService: AgentRuntimeService(
                runtimeClient: client,
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
            permissionClient: MockPermissionClient(issues: []),
            agentBuilderToolCatalogClient: nativeBundle.builderToolCatalogClient,
            runInlineCardActionHandler: RunInlineCardActionHandler(
                broker: nativeBundle.interactionBroker
            ),
            modelRoutingClient: RuntimeModelRoutingClient(runtimeClient: client)
        )
    }

    static func makeLastResortContainer(error: Error) -> AppContainer {
        let permissionStore = PermissionStore()
        let client = MockRuntimeClient(turnResult: degradedTurnResult())
        return AppContainer(
            runtimeService: AgentRuntimeService(
                runtimeClient: client,
                toolDriver: MinimalHostToolDriver()
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
            permissionClient: MockPermissionClient(issues: []),
            agentBuilderToolCatalogClient: StaticAgentBuilderToolCatalogClient(cards: []),
            runInlineCardActionHandler: RunInlineCardActionHandler(
                broker: NativeInteractionBroker(
                    store: InMemoryPendingUserInteractionStore(),
                    presenter: UnavailableNativeInteractionPresenter()
                )
            ),
            modelRoutingClient: RuntimeModelRoutingClient(runtimeClient: client)
        )
    }

    private static func makeRuntimeClient(
        environment: [String: String],
        providers: [RustRuntimeProviderConfiguration],
        store: RustRuntimeStoreConfiguration
    ) throws -> RustRuntimeClient {
        func client(for store: RustRuntimeStoreConfiguration) throws -> RustRuntimeClient {
            try RustRuntimeClient(configuration: RustRuntimeConfiguration(
                systemPrompt: AgentPromptDefaults.systemPrompt,
                runtimePolicy: AgentPromptDefaults.runtimePolicy,
                providerId: runtimeProviderId(environment: environment, providers: providers),
                store: store,
                providers: providers,
                agentOS: agentOSConfiguration(environment: environment)
            ))
        }

        do {
            return try client(for: store)
        } catch {
            guard case .sqlite(let path) = store else {
                throw error
            }

            let inMemoryClient = try client(for: .inMemory)
            do {
                try recoverSQLiteStore(atPath: path)
                return try client(for: store)
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
        let toolDriver = NativeHostToolDriver(toolkit: nativeToolkitClient)
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
        environment: [String: String],
        client: RustRuntimeClient,
        executionBridge: RustExecutionBridgeClient,
        toolDriver: any HostToolDriving
    ) -> ChatInteractionCoordinator? {
        // Keep this feature gated until Rust execution uses the verified ReAct worker path.
        // The migration adapter must not become the default app path.
        guard environment["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR"] == "1" else {
            return nil
        }

        let conversationBridge = RustConversationBridgeClient(gateway: client, legacyClient: client)
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
            toolDriver: toolDriver
        )
        return coordinator
    }

    private static func agentOSConfiguration(
        environment: [String: String]
    ) -> RustAgentOSConfiguration? {
        guard environment["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR"] == "1" else {
            return nil
        }

        return RustAgentOSConfiguration(seedDevelopmentProfile: true)
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
        if let providerId = environment["LOCAL_AGENT_DEFAULT_PROVIDER_ID"], !providerId.isEmpty {
            return providerId
        }

        let configuredProviders = providers ?? simulatorProviders(environment: environment)
        if configuredProviders.contains(where: { provider in
            if case .localLLM = provider {
                return true
            }
            return false
        }) {
            return "local_llm"
        }

        return "mock"
    }

    static func simulatorProviders(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [RustRuntimeProviderConfiguration] {
        guard let modelConfigJson = environment["LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON"],
              !modelConfigJson.isEmpty
        else {
            return []
        }

        return [
            .localLLM(
                model: "local.gguf.simulator",
                modelConfigJson: modelConfigJson,
                maxContextTokens: 2048
            ),
        ]
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
