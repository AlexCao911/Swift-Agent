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
        store: RustRuntimeStoreConfiguration? = nil,
        localAppSupportRoot: URL? = nil,
        remoteCatalog: Data? = nil,
        remoteCloudCatalog: Data? = nil
    ) async throws -> AppContainer {
        let appSupportRoot = try localAppSupportRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let container = try makeContainer(
            hostProcessEpoch: hostProcessEpoch,
            store: store,
            attachmentStoreRoot: appSupportRoot.appending(
                path: "LocalAgent/Attachments",
                directoryHint: .isDirectory
            )
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
        let modelExecutionRegistry = OpenMinisModelExecutionRegistry(
            persistenceURL: appSupportRoot.appending(
                path: "LocalAgent/LLM/provider-run-plans.json"
            )
        ) { runID, snapshot in
            switch snapshot.target.kind {
            case .local:
                RustReActModelRoute(
                    runID: runID,
                    local: local,
                    configuration: snapshot.configuration,
                    target: snapshot.target,
                    attachmentResolver: container.attachmentRepository
                )
            case .cloud:
                RustReActModelRoute(
                    runID: runID,
                    cloud: cloud,
                    configuration: snapshot.configuration,
                    target: snapshot.target,
                    attachmentResolver: container.attachmentRepository
                )
            }
        }
        let conversation = RustConversationBridgeClient(
            gateway: rust,
            legacyClient: rust
        )
        try await modelExecutionRegistry.reconcile(
            keeping: try await activeReactRunIDs(in: conversation)
        )
        let modelExecutor = OpenMinisModelExecutor(
            plans: modelExecutionRegistry,
            runtime: modelExecutionRegistry
        )
        let host = try await bootstrapLLMHost(
            container: container,
            modelExecutor: modelExecutor
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
            modelExecutionRegistry: modelExecutionRegistry,
            readinessIssues: Array(Set(readinessIssues)).sorted(),
            activeAgentProfile: activeAgentProfile,
            availableAgentProfiles: profiles
        )
    }

    private static func activeReactRunIDs(
        in conversation: any ConversationBridgeClient
    ) async throws -> Set<String> {
        var active = Set<String>()
        for session in try await conversation.listSessions() {
            let events = try await conversation.activeBranch(
                sessionId: session.sessionId,
                leafId: session.activeLeafId
            )
            let grouped = Dictionary(
                grouping: events.compactMap { event in
                    event.runId.map { ($0, event) }
                },
                by: { $0.0 }
            )
            for (runID, pairs) in grouped {
                let runEvents = pairs.map(\.1)
                let hasRunCommand = runEvents.contains {
                    [
                        "user_message",
                        "transcript_retry_requested",
                        "message_edited",
                    ].contains($0.kind.rawValue)
                }
                let terminal = runEvents.contains {
                    $0.kind == .runFailed
                        || $0.kind == .runCancelled
                        || (
                            $0.kind == .assistantMessageCompleted
                                && $0.id.hasSuffix("-final")
                        )
                }
                if hasRunCommand && !terminal {
                    active.insert(runID)
                }
            }
        }
        return active
    }

    static func bootstrapLLMHost(
        container: AppContainer,
        modelExecutor: any ModelGenerationExecuting
    ) async throws -> LLMHostProductRuntime {
        guard let rust = container.rustRuntimeClient else {
            throw LLMHostFailure(
                code: "execution.host_composition_unavailable",
                message: "production Rust host composition is unavailable"
            )
        }
        let nativeTools = await container.nativeToolkitClient
            .registrationSnapshot()
        return try await LLMHostProductRuntime.bootstrap(
            rust: rust,
            hostProcessEpoch: container.hostProcessEpoch,
            modelExecutor: modelExecutor,
            toolExecutor: OpenMinisToolBatchExecutor(
                dispatcher: OpenMinisProductToolDispatcher(
                    nativeTools: container.hostToolDriver
                ),
                definitions: try OpenMinisToolDefinitionSnapshotProvider
                    .productDefaults(nativeSchemas: nativeTools.schemas)
            )
        )
    }

    static func makeContainer(
        hostProcessEpoch: HostProcessEpoch,
        store: RustRuntimeStoreConfiguration? = nil,
        attachmentStoreRoot: URL? = nil
    ) throws -> AppContainer {
        LocalInferenceNativeLinkProbe.requireAllExports()
        let runtimeStore: RustRuntimeStoreConfiguration
        if let store {
            runtimeStore = store
        } else {
            runtimeStore = .sqlite(path: try sqliteURL().path)
        }
        let client = try makeRuntimeClient(
            store: runtimeStore,
            hostProcessEpoch: hostProcessEpoch
        )
        let executionBridge = RustExecutionBridgeClient(gateway: client, legacyClient: client)
        let nativeBundle = try makeNativeToolkitBundle()
        let selections = AppLLMHostSelectionRegistry()
        let hostStarter = AppHostRunStarter(selections: selections)
        let attachments = OpenMinisAttachmentRepository(
            directory: try attachmentStoreRoot ?? attachmentStoreURL(),
            policy: .productDefault
        )

        return AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runDebugService: RunDebugService(bridge: executionBridge),
            hostToolDriver: nativeBundle.toolDriver,
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
            availableAgentProfiles: [],
            cloudApprovalBroker: AppCloudApprovalBroker(),
            localLLMSubsystem: nil,
            cloudLLMSubsystem: nil,
            llmHostRuntime: nil,
            modelExecutionRegistry: nil,
            attachmentRepository: attachments
        )
    }

    static func makeDegradedContainer(
        error: Error,
        hostProcessEpoch: HostProcessEpoch
    ) throws -> AppContainer {
        let nativeBundle = try makeNativeToolkitBundle()
        let selections = AppLLMHostSelectionRegistry()
        let hostStarter = AppHostRunStarter(selections: selections)
        let attachments = OpenMinisAttachmentRepository(
            directory: try attachmentStoreURL(),
            policy: .productDefault
        )

        return AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runDebugService: nil,
            hostToolDriver: nativeBundle.toolDriver,
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
            availableAgentProfiles: [
                AgentProfileDTO(
                    profileId: "profile_1",
                    profileRevisionId: 1,
                    displayName: "Recovery Agent"
                ),
            ],
            cloudApprovalBroker: AppCloudApprovalBroker(),
            localLLMSubsystem: nil,
            cloudLLMSubsystem: nil,
            llmHostRuntime: nil,
            modelExecutionRegistry: nil,
            attachmentRepository: attachments
        )
    }

    static func makeLastResortContainer(
        error: Error,
        hostProcessEpoch: HostProcessEpoch
    ) -> AppContainer {
        let permissionStore = PermissionStore()
        let toolDriver = MinimalHostToolDriver()
        let selections = AppLLMHostSelectionRegistry()
        let hostStarter = AppHostRunStarter(selections: selections)
        let attachments = OpenMinisAttachmentRepository(
            directory: (try? attachmentStoreURL())
                ?? FileManager.default.temporaryDirectory.appending(
                    path: "LocalAgent-Fallback-Attachments",
                    directoryHint: .isDirectory
                ),
            policy: .productDefault
        )
        return AppContainer(
            hostProcessEpoch: hostProcessEpoch,
            runDebugService: nil,
            hostToolDriver: toolDriver,
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
            availableAgentProfiles: [],
            cloudApprovalBroker: AppCloudApprovalBroker(),
            localLLMSubsystem: nil,
            cloudLLMSubsystem: nil,
            llmHostRuntime: nil,
            modelExecutionRegistry: nil,
            attachmentRepository: attachments
        )
    }

    private static func makeRuntimeClient(
        store: RustRuntimeStoreConfiguration,
        hostProcessEpoch: HostProcessEpoch
    ) throws -> RustRuntimeClient {
        func client(for store: RustRuntimeStoreConfiguration) throws -> RustRuntimeClient {
            try RustRuntimeClient(configuration: RustRuntimeConfiguration(
                hostProcessEpoch: hostProcessEpoch,
                store: store,
                agentOS: agentOSConfiguration()
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

    static func transcriptProjectionURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        try sqliteURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("transcript-projection.sqlite")
    }

    static func attachmentStoreURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try sqliteURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
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
