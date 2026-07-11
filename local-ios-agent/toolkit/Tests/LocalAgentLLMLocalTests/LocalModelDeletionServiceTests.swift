import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Guarded local model deletion")
struct LocalModelDeletionServiceTests {
    @Test(arguments: [LocalModelUseLease.Purpose.loaded, .activeSession])
    func activeUseLeaseBlocksDeletion(_ purpose: LocalModelUseLease.Purpose) throws {
        let fixture = try installedDeletionFixture()
        let epoch = try HostProcessEpoch.generate()
        let lease = LocalModelUseLease(
            leaseID: "lease-\(purpose.rawValue)",
            installationID: fixture.installationID,
            purpose: purpose,
            hostProcessEpoch: epoch,
            state: .active,
            leaseRevision: 1
        )
        try fixture.store.acquireModelUseLease(lease)
        let service = LocalModelDeletionService(store: fixture.store, paths: fixture.paths)

        try expectDeletionFailure("deletion.model_in_use") {
            try service.delete(installationID: fixture.installationID)
        }
        #expect(FileManager.default.fileExists(
            atPath: try fixture.paths.finalInstallation(fixture.installationID).path
        ))
    }

    @Test(arguments: [
        LocalInstallationState.downloading,
        .paused,
        .verifying,
    ])
    func activeDownloadStatesRequireCancellationFirst(_ state: LocalInstallationState) throws {
        let fixture = try TestLocalInstallFixture(installationID: "state-\(state.rawValue)")
        _ = try fixture.store.enqueueInstallation(
            installationID: fixture.installationID,
            modelRevision: fixture.manifest.id,
            rootPath: try fixture.paths.finalInstallation(fixture.installationID).path
        )
        let storedSummary = try fixture.store.installationSummary(
            installationID: fixture.installationID
        )
        var summary = try #require(storedSummary)
        summary = try fixture.store.transitionInstallation(
            installationID: fixture.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .downloading
        )
        if state == .paused {
            summary = try fixture.store.transitionInstallation(
                installationID: fixture.installationID,
                expectedStateRevision: summary.stateRevision,
                to: .paused
            )
        } else if state == .verifying {
            summary = try fixture.store.transitionInstallation(
                installationID: fixture.installationID,
                expectedStateRevision: summary.stateRevision,
                to: .verifying
            )
        }
        let service = LocalModelDeletionService(store: fixture.store, paths: fixture.paths)

        try expectDeletionFailure("deletion.cancellation_required") {
            try service.delete(installationID: fixture.installationID)
        }
    }

    @Test
    func unusedInstalledModelMovesToTrashThenDeletesIdempotently() throws {
        let fixture = try installedDeletionFixture()
        let service = LocalModelDeletionService(store: fixture.store, paths: fixture.paths)

        try service.delete(installationID: fixture.installationID)
        try service.delete(installationID: fixture.installationID)

        #expect(try fixture.store.installationSummary(installationID: fixture.installationID) == nil)
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.paths.trashRoot,
            includingPropertiesForKeys: nil
        ).isEmpty)
        #expect(try fixture.store.unfinishedFilesystemOperations().isEmpty)
    }

    @Test
    func deletingOneInstallationDoesNotAffectAnotherRevision() throws {
        let fixture = try installedDeletionFixture()
        let otherID = "other-installation"
        let otherRevision = LocalModelRevisionID(modelID: "other-model", revision: 2)
        _ = try fixture.store.enqueueInstallation(
            installationID: otherID,
            modelRevision: otherRevision,
            rootPath: try fixture.paths.finalInstallation(otherID).path
        )
        let storedOther = try fixture.store.installationSummary(installationID: otherID)
        var other = try #require(storedOther)
        other = try fixture.store.transitionInstallation(
            installationID: otherID,
            expectedStateRevision: other.stateRevision,
            to: .downloading
        )
        other = try fixture.store.transitionInstallation(
            installationID: otherID,
            expectedStateRevision: other.stateRevision,
            to: .verifying
        )
        _ = try fixture.store.transitionInstallation(
            installationID: otherID,
            expectedStateRevision: other.stateRevision,
            to: .installed
        )
        try FileManager.default.createDirectory(
            at: fixture.paths.finalInstallation(otherID),
            withIntermediateDirectories: true
        )

        try LocalModelDeletionService(store: fixture.store, paths: fixture.paths)
            .delete(installationID: fixture.installationID)

        #expect(try fixture.store.installationSummary(installationID: otherID)?.state == .installed)
        #expect(FileManager.default.fileExists(
            atPath: try fixture.paths.finalInstallation(otherID).path
        ))
    }

    @Test
    func crashAfterTrashMoveIsFinishedByLaunchReconciliation() throws {
        let fixture = try installedDeletionFixture()
        let crashing = LocalModelDeletionService(
            store: fixture.store,
            paths: fixture.paths,
            crashPointForTesting: .afterTrashMove
        )
        #expect(throws: LLMFailure.self) {
            try crashing.delete(installationID: fixture.installationID)
        }
        #expect(try fixture.store.installationSummary(
            installationID: fixture.installationID
        )?.state == .deleting)
        try expectDeletionFailure("runtime.local_model_not_installed") {
            try fixture.store.acquireModelUseLease(LocalModelUseLease(
                leaseID: "late-lease",
                installationID: fixture.installationID,
                purpose: .loaded,
                hostProcessEpoch: try HostProcessEpoch.generate(),
                state: .active,
                leaseRevision: 1
            ))
        }
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [fixture.manifest.id: fixture.manifest],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        _ = try reconciler.reconcileAtLaunch()
        _ = try reconciler.reconcileAtLaunch()

        #expect(try fixture.store.installationSummary(installationID: fixture.installationID) == nil)
        #expect(try fixture.store.unfinishedFilesystemOperations().isEmpty)
    }
}

private func installedDeletionFixture() throws -> TestLocalInstallFixture {
    let fixture = try TestLocalInstallFixture(installationID: "delete-installed")
    try fixture.prepareVerifyingInstallation()
    try LocalModelInstaller(
        store: fixture.store,
        paths: fixture.paths,
        validator: fixture.validator,
        backupExclusion: fixture.backup
    ).verifyAndInstall(installationID: fixture.installationID, manifest: fixture.manifest)
    return fixture
}

private func expectDeletionFailure(_ code: String, operation: () throws -> Void) throws {
    do {
        try operation()
        Issue.record("expected deletion failure \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    }
}
