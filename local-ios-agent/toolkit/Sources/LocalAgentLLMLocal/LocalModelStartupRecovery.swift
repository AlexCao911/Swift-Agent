import Foundation
import LocalAgentLLMContracts

package struct LocalStartupRecoveryResult: Sendable {
    let hostProcessEpoch: HostProcessEpoch
    let acceptedCatalog: AcceptedLocalModelCatalog
}

package enum LocalStartupRecoveryStage: String, Equatable, Sendable {
    case epochReceived = "epoch_received"
    case storeReady = "store_ready"
    case oldEpochEnded = "old_epoch_ended"
    case catalogAccepted = "catalog_accepted"
    case filesystemReconciled = "filesystem_reconciled"
    case downloadsRestored = "downloads_restored"
}

package enum LocalStartupRecoveryCrashPoint: String, CaseIterable, Sendable {
    case afterOldEpochRecovery = "after_old_epoch_recovery"
    case afterCatalogAcceptance = "after_catalog_acceptance"
    case afterFilesystemReconciliation = "after_filesystem_reconciliation"
    case afterDownloadRestoration = "after_download_restoration"
}

package enum LocalModelStartupRecovery {
    package static func run(
        store: LocalModelStore,
        hostProcessEpoch: HostProcessEpoch,
        bundledCatalog: Data,
        remoteCatalog: Data?,
        reconciler: LocalModelReconciler,
        downloads: ModelDownloadCoordinator,
        crashPointForTesting: LocalStartupRecoveryCrashPoint? = nil,
        stageObserver: (@Sendable (LocalStartupRecoveryStage) -> Void)? = nil
    ) async throws -> LocalStartupRecoveryResult {
        stageObserver?(.epochReceived)
        stageObserver?(.storeReady)

        try store.recoverLocalSessionsAndUseLeasesForNewEpoch(hostProcessEpoch)
        stageObserver?(.oldEpochEnded)
        try injectCrash(.afterOldEpochRecovery, selected: crashPointForTesting)

        let catalog = try OfficialModelCatalogService(store: store).accept(
            bundled: bundledCatalog,
            remote: remoteCatalog
        )
        stageObserver?(.catalogAccepted)
        try injectCrash(.afterCatalogAcceptance, selected: crashPointForTesting)

        let filesystem = try reconciler.reconcileAtLaunch()
        stageObserver?(.filesystemReconciled)
        try injectCrash(.afterFilesystemReconciliation, selected: crashPointForTesting)

        try await downloads.restore(
            pendingCancellations: filesystem.pendingTransportCancellations
        )
        stageObserver?(.downloadsRestored)
        try injectCrash(.afterDownloadRestoration, selected: crashPointForTesting)

        return LocalStartupRecoveryResult(
            hostProcessEpoch: hostProcessEpoch,
            acceptedCatalog: catalog
        )
    }

    private static func injectCrash(
        _ point: LocalStartupRecoveryCrashPoint,
        selected: LocalStartupRecoveryCrashPoint?
    ) throws {
        guard point == selected else { return }
        throw LLMFailure(
            code: "runtime.local_startup_recovery_incomplete",
            message: "local runtime startup recovery did not complete",
            retryable: true
        )
    }
}
