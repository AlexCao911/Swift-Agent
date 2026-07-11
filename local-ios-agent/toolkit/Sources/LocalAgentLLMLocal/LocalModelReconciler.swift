import Foundation
import LocalAgentLLMContracts

package struct LocalFilesystemRecoveryResult: Equatable, Sendable {
    let pendingTransportCancellations: [PendingTransportCancellation]
}

package struct LocalModelReconciler: Sendable {
    private let store: LocalModelStore
    private let paths: LocalModelPaths
    private let manifestsByRevision: [LocalModelRevisionID: LocalModelRevisionManifest]
    private let installer: LocalModelInstaller

    package init(
        store: LocalModelStore,
        paths: LocalModelPaths,
        manifestsByRevision: [LocalModelRevisionID: LocalModelRevisionManifest],
        validator: any LocalModelConfigValidator,
        backupExclusion: any LocalBackupExclusionApplying = SystemLocalBackupExclusion()
    ) {
        self.store = store
        self.paths = paths
        self.manifestsByRevision = manifestsByRevision
        installer = LocalModelInstaller(
            store: store,
            paths: paths,
            validator: validator,
            backupExclusion: backupExclusion
        )
    }

    package func reconcileAtLaunch() throws -> LocalFilesystemRecoveryResult {
        var pendingCancellations: [PendingTransportCancellation] = []
        let initialOperations = try store.unfinishedFilesystemOperations()
        for operation in initialOperations {
            switch operation.kind {
            case .promoteInstallation:
                guard let installation = try store.installationRecord(
                    installationID: operation.installationID
                ), let manifest = manifestsByRevision[installation.modelRevision]
                else {
                    try? store.failPromotion(
                        operationID: operation.operationID,
                        failureCode: "installation.interrupted"
                    )
                    continue
                }
                do {
                    try installer.resumePromotion(
                        operationID: operation.operationID,
                        manifest: manifest
                    )
                } catch is LLMFailure {
                    // The installer persisted a stable failed state or left a replayable intent.
                }
            case .cancelDownload:
                guard let taskIdentifier = operation.taskIdentifier else { continue }
                pendingCancellations.append(PendingTransportCancellation(
                    operationID: operation.operationID,
                    taskIdentifier: taskIdentifier,
                    installationID: operation.installationID
                ))
            case .deleteInstallation:
                try LocalModelDeletionService(store: store, paths: paths)
                    .resumeDeletion(operationID: operation.operationID)
            }
        }

        try reconcileInstalledRecords()
        try removeOrphanStagingDirectories()
        try quarantineOrphanFinalDirectories()
        try removeOrphanTrashDirectories()
        return LocalFilesystemRecoveryResult(
            pendingTransportCancellations: pendingCancellations.sorted {
                $0.operationID < $1.operationID
            }
        )
    }

    private func reconcileInstalledRecords() throws {
        for installation in try store.installationRecords() where installation.state == .installed {
            let final = try paths.finalInstallation(installation.installationID)
            guard !FileManager.default.fileExists(atPath: final.path) else { continue }
            _ = try store.transitionInstallation(
                installationID: installation.installationID,
                expectedStateRevision: installation.stateRevision,
                to: .failed,
                failureCode: "installation.interrupted"
            )
        }
    }

    private func removeOrphanStagingDirectories() throws {
        for directory in try childDirectories(of: paths.stagingRoot) {
            let installationID = directory.lastPathComponent
            guard let installation = try store.installationRecord(
                installationID: installationID
            ) else {
                try FileManager.default.removeItem(at: directory)
                continue
            }
            let hasTask = try store.artifactRecords(installationID: installationID)
                .contains { $0.taskIdentifier != nil }
            let hasPromotion = try store.unfinishedFilesystemOperations().contains {
                $0.installationID == installationID && $0.kind == .promoteInstallation
            }
            if !hasTask, !hasPromotion, installation.state == .failed || installation.state == .installed {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func quarantineOrphanFinalDirectories() throws {
        for directory in try childDirectories(of: paths.installationsRoot) {
            let installationID = directory.lastPathComponent
            let installation = try store.installationRecord(installationID: installationID)
            guard installation?.state != .installed else { continue }
            let trash = try paths.trashedInstallation(installationID)
            if FileManager.default.fileExists(atPath: trash.path) {
                try FileManager.default.removeItem(at: trash)
            }
            try FileManager.default.moveItem(at: directory, to: trash)
            try FileManager.default.removeItem(at: trash)
        }
    }

    private func removeOrphanTrashDirectories() throws {
        for directory in try childDirectories(of: paths.trashRoot) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

private func childDirectories(of root: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ).filter {
        try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}
