import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local model launch reconciliation")
struct LocalModelReconcilerTests {
    @Test(arguments: [
        LocalModelInstallationCrashPoint.afterPromotionIntent,
        .afterFilesystemRename,
    ])
    func promotionCrashReplaysIdempotently(_ crashPoint: LocalModelInstallationCrashPoint) throws {
        let fixture = try TestLocalInstallFixture(installationID: "crash-\(crashPoint.rawValue)")
        try fixture.prepareVerifyingInstallation()
        let crashing = LocalModelInstaller(
            store: fixture.store,
            paths: fixture.paths,
            validator: fixture.validator,
            backupExclusion: fixture.backup,
            crashPointForTesting: crashPoint
        )
        #expect(throws: LLMFailure.self) {
            try crashing.verifyAndInstall(
                installationID: fixture.installationID,
                manifest: fixture.manifest
            )
        }
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [fixture.manifest.id: fixture.manifest],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        let first = try reconciler.reconcileAtLaunch()
        let second = try reconciler.reconcileAtLaunch()

        #expect(first.pendingTransportCancellations.isEmpty)
        #expect(second.pendingTransportCancellations.isEmpty)
        let storedSummary = try fixture.store.installationSummary(
            installationID: fixture.installationID
        )
        let summary = try #require(storedSummary)
        #expect(summary.state == .installed)
        #expect(try fixture.store.unfinishedFilesystemOperations().isEmpty)
    }

    @Test
    func removesOrphanStagingAndFinalDirectories() throws {
        let fixture = try TestLocalInstallFixture()
        let orphanStaging = try fixture.paths.stagingInstallation("orphan-staging")
        let orphanFinal = try fixture.paths.finalInstallation("orphan-final")
        try FileManager.default.createDirectory(at: orphanStaging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphanFinal, withIntermediateDirectories: true)
        try Data([1]).write(to: orphanStaging.appending(path: "file"))
        try Data([2]).write(to: orphanFinal.appending(path: "file"))
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [:],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        _ = try reconciler.reconcileAtLaunch()

        #expect(!FileManager.default.fileExists(atPath: orphanStaging.path))
        #expect(!FileManager.default.fileExists(atPath: orphanFinal.path))
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.trashRoot,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test
    func installedRecordWithoutDirectoryBecomesInterruptedFailure() throws {
        let fixture = try TestLocalInstallFixture()
        try fixture.prepareVerifyingInstallation()
        let installer = LocalModelInstaller(
            store: fixture.store,
            paths: fixture.paths,
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )
        try installer.verifyAndInstall(
            installationID: fixture.installationID,
            manifest: fixture.manifest
        )
        try FileManager.default.removeItem(
            at: fixture.paths.finalInstallation(fixture.installationID)
        )
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [fixture.manifest.id: fixture.manifest],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        _ = try reconciler.reconcileAtLaunch()

        let storedSummary = try fixture.store.installationSummary(
            installationID: fixture.installationID
        )
        let summary = try #require(storedSummary)
        #expect(summary.state == .failed)
        #expect(summary.failureCode == "installation.interrupted")
    }

    @Test
    func cancelIntentIsReturnedWithoutDeletingTaskOrStaging() throws {
        let fixture = try TestLocalInstallFixture()
        _ = try fixture.store.enqueueInstallation(
            installationID: fixture.installationID,
            modelRevision: fixture.manifest.id,
            rootPath: try fixture.paths.finalInstallation(fixture.installationID).path
        )
        let artifact = try #require(fixture.manifest.artifacts.first)
        try fixture.store.recordArtifact(
            installationID: fixture.installationID,
            artifactID: artifact.artifactID,
            relativePath: artifact.relativePath,
            downloadURL: artifact.downloadURL,
            expectedBytes: artifact.byteSize,
            artifactSHA256: artifact.artifactSHA256
        )
        let storedRecord = try fixture.store.artifactRecord(
            installationID: fixture.installationID,
            artifactID: artifact.artifactID
        )
        let record = try #require(storedRecord)
        _ = try fixture.store.updateArtifactTransfer(
            installationID: fixture.installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: record.stateRevision,
            receivedBytes: 0,
            resumeData: nil,
            etag: nil,
            lastModified: nil,
            taskIdentifier: 77
        )
        let staging = try fixture.paths.stagingInstallation(fixture.installationID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let operation = try fixture.store.createFilesystemOperation(
            operationID: "cancel-recovery",
            installationID: fixture.installationID,
            kind: .cancelDownload,
            taskIdentifier: 77
        )
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [fixture.manifest.id: fixture.manifest],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        let result = try reconciler.reconcileAtLaunch()

        #expect(result.pendingTransportCancellations == [
            PendingTransportCancellation(
                operationID: operation.operationID,
                taskIdentifier: 77,
                installationID: fixture.installationID
            ),
        ])
        #expect(FileManager.default.fileExists(atPath: staging.path))
        #expect(try fixture.store.artifactRecord(taskIdentifier: 77) != nil)
    }
}
