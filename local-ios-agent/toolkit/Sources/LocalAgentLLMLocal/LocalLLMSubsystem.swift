import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public struct LocalLLMSubsystem: Sendable {
    public let hostProcessEpoch: HostProcessEpoch
    public let downloads: ModelDownloadCoordinator
    public let runtime: LocalModelRuntime
    public let acceptedCatalog: AcceptedLocalModelCatalog
    package let store: LocalModelStore
    package let bindingStore: LLMStore

    private init(
        hostProcessEpoch: HostProcessEpoch,
        downloads: ModelDownloadCoordinator,
        runtime: LocalModelRuntime,
        acceptedCatalog: AcceptedLocalModelCatalog,
        store: LocalModelStore,
        bindingStore: LLMStore
    ) {
        self.hostProcessEpoch = hostProcessEpoch
        self.downloads = downloads
        self.runtime = runtime
        self.acceptedCatalog = acceptedCatalog
        self.store = store
        self.bindingStore = bindingStore
    }

    public static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        remoteCatalog: Data?
    ) async throws -> LocalLLMSubsystem {
        let resources = try OfficialModelCatalogResources.loadBundled()
        return try await bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: hostProcessEpoch,
            bundledCatalog: resources.envelope,
            remoteCatalog: remoteCatalog,
            transport: URLSessionModelDownloadTransport(),
            inference: CppInferenceClient.live
        )
    }

    package static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        bundledCatalog: Data,
        remoteCatalog: Data?,
        transport: any ModelDownloadTransport,
        inference: any CppInferenceAPI
    ) async throws -> LocalLLMSubsystem {
        let store = try LocalModelStore.default(appSupportRoot: appSupportRoot)
        let paths = try LocalModelPaths(
            root: appSupportRoot.appending(path: "LocalAgent/LLM/models", directoryHint: .isDirectory)
        )
        try store.recoverLocalSessionsAndUseLeasesForNewEpoch(hostProcessEpoch)
        let accepted = try OfficialModelCatalogService(store: store).accept(
            bundled: bundledCatalog,
            remote: remoteCatalog
        )
        let downloads = ModelDownloadCoordinator(
            store: store,
            paths: paths,
            transport: transport
        )
        let validator = InferenceModelValidator(inference: inference)
        let reconciler = LocalModelReconciler(
            store: store,
            paths: paths,
            manifestsByRevision: accepted.verified.models,
            validator: validator
        )
        let filesystem = try reconciler.reconcileAtLaunch()
        try await downloads.restore(
            pendingCancellations: filesystem.pendingTransportCancellations
        )
        let bindingStoreURL = appSupportRoot.appending(
            path: "LocalAgent/LLM/llm-state.sqlite"
        )
        let bindingStore = try LLMStore(fileURL: bindingStoreURL)
        let runtime = LocalModelRuntime(
            store: store,
            paths: paths,
            catalog: accepted,
            bindingSaga: AgentHostBindingSaga(store: bindingStore),
            inference: inference,
            hostProcessEpoch: hostProcessEpoch,
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
        )
        return LocalLLMSubsystem(
            hostProcessEpoch: hostProcessEpoch,
            downloads: downloads,
            runtime: runtime,
            acceptedCatalog: accepted,
            store: store,
            bindingStore: bindingStore
        )
    }
}

private struct InferenceModelValidator: LocalModelConfigValidator {
    let inference: any CppInferenceAPI

    func validate(
        manifest: LocalModelRevisionManifest,
        artifactPathsByRole: [LocalModelArtifactRole: URL]
    ) throws {
        try inference.validateModel(CppModelLoadRequest(
            engineID: manifest.engineID,
            modelID: manifest.id.modelID,
            modelFormat: manifest.modelFormat,
            artifactPathsByRole: Dictionary(uniqueKeysWithValues: artifactPathsByRole.map {
                ($0.key.rawValue, $0.value.path)
            }),
            contextTokens: manifest.loadTemplate.contextTokens,
            manifestLoadOptions: manifest.loadTemplate.manifestControlledOptions,
            template: manifest.chatTemplate,
            toolCallCodecID: manifest.toolCallCodecID
        ))
    }
}
