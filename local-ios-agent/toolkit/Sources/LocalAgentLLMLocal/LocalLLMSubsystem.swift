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
    private let paths: LocalModelPaths
    private let diskPolicy: LocalDiskPolicy
    private let volume: any LocalVolumeCapacity
    private let compatibilityPolicy: LocalDeviceCompatibilityPolicy

    private init(
        hostProcessEpoch: HostProcessEpoch,
        downloads: ModelDownloadCoordinator,
        runtime: LocalModelRuntime,
        acceptedCatalog: AcceptedLocalModelCatalog,
        store: LocalModelStore,
        bindingStore: LLMStore,
        paths: LocalModelPaths,
        volume: any LocalVolumeCapacity,
        compatibilityPolicy: LocalDeviceCompatibilityPolicy
    ) {
        self.hostProcessEpoch = hostProcessEpoch
        self.downloads = downloads
        self.runtime = runtime
        self.acceptedCatalog = acceptedCatalog
        self.store = store
        self.bindingStore = bindingStore
        self.paths = paths
        diskPolicy = LocalDiskPolicy(store: store, root: paths.root)
        self.volume = volume
        self.compatibilityPolicy = compatibilityPolicy
    }

    public var downloadStateChanges: AsyncStream<Void> {
        downloads.stateChanges
    }

    public func inventory() async throws -> [LocalModelProductState] {
        try store.installationRecords().map { installation in
            let manifest = acceptedCatalog.verified.models[installation.modelRevision]
            let artifacts = try store.artifactRecords(
                installationID: installation.installationID
            )
            let receivedBytes = try sum(artifacts.map(\.receivedBytes))
            let expectedBytes = try sum(artifacts.map(\.expectedBytes))
            let requiredBytes = manifest?.installedByteSize ?? expectedBytes
            let catalogStatus: LocalModelCatalogStatus
            if let manifest {
                catalogStatus = compatibilityPolicy.compatibility(of: manifest)
                    == .compatible ? .current : .incompatible
            } else {
                catalogStatus = .superseded
            }
            return LocalModelProductState(
                installationID: installation.installationID,
                modelRevision: installation.modelRevision,
                state: installation.state,
                receivedBytes: receivedBytes,
                expectedBytes: expectedBytes,
                installedBytes: installation.state == .installed
                    ? requiredBytes : 0,
                requiredBytes: requiredBytes,
                repairAction: repairAction(for: installation.state),
                catalogStatus: catalogStatus
            )
        }
    }

    public func compatibleModels() -> [LocalModelRevisionManifest] {
        acceptedCatalog.verified.models.values.filter {
            compatibilityPolicy.compatibility(of: $0) == .compatible
        }
    }

    @discardableResult
    public func enqueue(
        modelRevision: LocalModelRevisionID,
        installationID: String = UUID().uuidString.lowercased()
    ) async throws -> String {
        guard let manifest = acceptedCatalog.verified.models[modelRevision] else {
            throw LLMFailure(
                code: "download.catalog_revision_missing",
                message: "model revision is absent from the accepted catalog",
                retryable: false
            )
        }
        try compatibilityPolicy.requireCompatibility(of: manifest)
        let existed = try store.installationRecord(installationID: installationID) != nil
        if !existed {
            _ = try store.enqueueInstallation(
                installationID: installationID,
                modelRevision: manifest.id,
                rootPath: try paths.finalInstallation(installationID).path
            )
        }
        do {
            _ = try await diskPolicy.preflight(
                installationID: installationID,
                manifest: manifest,
                completedArtifactBytes: 0,
                volume: volume
            )
            try await downloads.enqueue(
                installationID: installationID,
                manifest: manifest
            )
        } catch {
            if !existed,
               try store.installationSummary(installationID: installationID)?.state == .queued {
                try? store.discardQueuedInstallation(installationID: installationID)
            }
            throw error
        }
        return installationID
    }

    public func pause(installationID: String) async throws {
        try await downloads.pause(installationID: installationID)
    }

    public func resume(installationID: String) async throws {
        guard let installation = try store.installationRecord(installationID: installationID) else {
            throw LLMFailure(
                code: "download.installation_not_found",
                message: "installation is missing",
                retryable: false
            )
        }
        if installation.state == .failed {
            guard let manifest = acceptedCatalog.verified.models[installation.modelRevision] else {
                throw LLMFailure(
                    code: "download.catalog_revision_missing",
                    message: "superseded model revisions cannot be downloaded again",
                    retryable: false
                )
            }
            try compatibilityPolicy.requireCompatibility(of: manifest)
            _ = try await diskPolicy.preflight(
                installationID: installationID,
                manifest: manifest,
                completedArtifactBytes: 0,
                volume: volume
            )
            do {
                try await downloads.retry(
                    installationID: installationID,
                    manifest: manifest
                )
            } catch {
                try? store.releaseDiskReservation(installationID: installationID)
                throw error
            }
        } else {
            try await downloads.resume(installationID: installationID)
        }
    }

    public func cancel(installationID: String) async throws {
        try await downloads.cancel(installationID: installationID)
    }

    public func delete(installationID: String) async throws {
        try LocalModelDeletionService(store: store, paths: paths)
            .delete(installationID: installationID)
    }

    public func diskState() async throws -> LocalDiskProductState {
        let installedBytes = try sum(try store.installationRecords().compactMap {
            guard $0.state == .installed else { return nil }
            if let bytes = acceptedCatalog.verified.models[$0.modelRevision]?.installedByteSize {
                return bytes
            }
            return try sum(try store.artifactRecords(
                installationID: $0.installationID
            ).map(\.expectedBytes))
        })
        return LocalDiskProductState(
            availableImportantUsageBytes: try volume.availableImportantUsageBytes(
                at: paths.root
            ),
            reservedBytes: try store.totalReservedBytes(),
            installedBytes: installedBytes
        )
    }

    public static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        remoteCatalog: Data?,
        llmStore: LLMStore? = nil
    ) async throws -> LocalLLMSubsystem {
        let resources = try OfficialModelCatalogResources.loadBundled()
        return try await bootstrap(
            appSupportRoot: appSupportRoot,
            hostProcessEpoch: hostProcessEpoch,
            bundledCatalog: resources.envelope,
            remoteCatalog: remoteCatalog,
            transport: URLSessionModelDownloadTransport(),
            inference: CppInferenceClient.live,
            llmStore: llmStore,
            deviceCapabilities: await LocalDeviceCapabilities.current(),
            volume: SystemLocalVolumeCapacity()
        )
    }

    package static func bootstrap(
        appSupportRoot: URL,
        hostProcessEpoch: HostProcessEpoch,
        bundledCatalog: Data,
        remoteCatalog: Data?,
        transport: any ModelDownloadTransport,
        inference: any CppInferenceAPI,
        llmStore: LLMStore? = nil,
        deviceCapabilities: LocalDeviceCapabilities? = nil,
        volume: any LocalVolumeCapacity = SystemLocalVolumeCapacity()
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
        let validator = InferenceModelValidator(inference: inference)
        let installer = LocalModelInstaller(
            store: store,
            paths: paths,
            validator: validator
        )
        let downloads = ModelDownloadCoordinator(
            store: store,
            paths: paths,
            transport: transport,
            installer: installer,
            manifestsByRevision: accepted.verified.models
        )
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
        let bindingStore = try llmStore ?? LLMStore(fileURL: bindingStoreURL)
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
        let resolvedDeviceCapabilities: LocalDeviceCapabilities
        if let deviceCapabilities {
            resolvedDeviceCapabilities = deviceCapabilities
        } else {
            resolvedDeviceCapabilities = await LocalDeviceCapabilities.current()
        }
        return LocalLLMSubsystem(
            hostProcessEpoch: hostProcessEpoch,
            downloads: downloads,
            runtime: runtime,
            acceptedCatalog: accepted,
            store: store,
            bindingStore: bindingStore,
            paths: paths,
            volume: volume,
            compatibilityPolicy: LocalDeviceCompatibilityPolicy(
                device: resolvedDeviceCapabilities
            )
        )
    }
}

private func repairAction(for state: LocalInstallationState) -> LocalModelRepairAction {
    switch state {
    case .paused: .resume
    case .failed: .retry
    case .queued, .downloading, .verifying: .cancel
    case .installed: .delete
    case .deleting: .none
    }
}

private func sum(_ values: [UInt64]) throws -> UInt64 {
    try values.reduce(0) { total, value in
        let (result, overflow) = total.addingReportingOverflow(value)
        guard !overflow else {
            throw LLMFailure(
                code: "download.size_overflow",
                message: "local model byte total overflowed",
                retryable: false
            )
        }
        return result
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
