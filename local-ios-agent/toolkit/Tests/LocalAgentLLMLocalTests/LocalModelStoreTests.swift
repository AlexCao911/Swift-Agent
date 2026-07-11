import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local model SQLite store")
struct LocalModelStoreTests {
    @Test
    func defaultPathAndNormalizedSchemaAreIndependentFromPhaseOneStore() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let backupExclusion = RecordingBackupExclusion()
        let store = try LocalModelStore.default(
            appSupportRoot: root,
            backupExclusion: backupExclusion
        )
        #expect(store.fileURL == root.appending(path: "LocalAgent/LLM/local-models.sqlite"))
        #expect(store.schemaVersionForTesting() == 2)
        #expect(Set(store.tableNamesForTesting()) == [
            "local_catalog_state",
            "local_installations",
            "local_artifacts",
            "local_download_queue",
            "local_disk_reservations",
            "local_filesystem_operations",
            "local_model_use_leases",
            "prepared_local_sessions",
        ])
        #expect(!store.fileURL.path.hasSuffix("llm-state.sqlite"))
        let excluded = Set(backupExclusion.urls.map(\.path))
        #expect(excluded.contains(store.fileURL.deletingLastPathComponent().path))
        #expect(excluded.contains(store.fileURL.path))
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: store.fileURL.path + suffix)
            #expect(FileManager.default.fileExists(atPath: sidecar.path))
            #expect(excluded.contains(sidecar.path))
        }

        let liveRoot = root.appending(path: "live", directoryHint: .isDirectory)
        let liveStore = try LocalModelStore.default(appSupportRoot: liveRoot)
        #expect(liveStore.fileURL == liveRoot.appending(path: "LocalAgent/LLM/local-models.sqlite"))
    }

    @Test
    func lifecycleAllowsOnlySpecifiedTransitionsAndDeletionRemovesTheRow() throws {
        let store = try LocalModelStore.inMemory()
        var summary = try enqueue(store, id: "install-main", modelID: "model-main")
        #expect(summary.state == .queued)
        #expect(summary.stateRevision == 1)

        try expectFailure("download.state_transition_invalid") {
            try store.transitionInstallation(
                installationID: summary.installationID,
                expectedStateRevision: summary.stateRevision,
                to: .installed
            )
        }
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .downloading
        )
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .paused
        )
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .downloading
        )
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .verifying
        )
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .installed
        )
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .deleting
        )
        try store.completeDeletion(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision
        )
        #expect(try store.installationSummary(installationID: summary.installationID) == nil)
    }

    @Test
    func failureRequiresExplicitRetryAndEveryDownloadStateCanFail() throws {
        for (index, targetState) in [
            LocalInstallationState.queued,
            .downloading,
            .paused,
            .verifying,
        ].enumerated() {
            let store = try LocalModelStore.inMemory()
            var summary = try enqueue(store, id: "failure-\(index)", modelID: "model-\(index)")
            if targetState != .queued {
                summary = try store.transitionInstallation(
                    installationID: summary.installationID,
                    expectedStateRevision: summary.stateRevision,
                    to: .downloading
                )
            }
            if targetState == .paused {
                summary = try store.transitionInstallation(
                    installationID: summary.installationID,
                    expectedStateRevision: summary.stateRevision,
                    to: .paused
                )
            } else if targetState == .verifying {
                summary = try store.transitionInstallation(
                    installationID: summary.installationID,
                    expectedStateRevision: summary.stateRevision,
                    to: .verifying
                )
            }
            summary = try store.transitionInstallation(
                installationID: summary.installationID,
                expectedStateRevision: summary.stateRevision,
                to: .failed,
                failureCode: "download.network_failed"
            )
            try expectFailure("download.state_transition_invalid") {
                try store.transitionInstallation(
                    installationID: summary.installationID,
                    expectedStateRevision: summary.stateRevision,
                    to: .queued
                )
            }
            summary = try store.transitionInstallation(
                installationID: summary.installationID,
                expectedStateRevision: summary.stateRevision,
                to: .queued,
                explicitRetry: true
            )
            #expect(summary.failureCode == nil)
        }
    }

    @Test
    func transitionMatrixRejectsEveryUnspecifiedEdge() throws {
        let allowed: Set<String> = [
            "queued->downloading", "queued->failed",
            "downloading->paused", "downloading->verifying", "downloading->failed",
            "paused->downloading", "paused->failed",
            "verifying->installed", "verifying->failed",
            "failed->queued", "installed->deleting", "installed->failed",
        ]
        for source in LocalInstallationState.allCases {
            for destination in LocalInstallationState.allCases {
                let store = try LocalModelStore.inMemory()
                var summary = try enqueue(
                    store,
                    id: "\(source.rawValue)-\(destination.rawValue)",
                    modelID: UUID().uuidString
                )
                summary = try drive(store, summary: summary, to: source)
                let edge = "\(source.rawValue)->\(destination.rawValue)"
                let operation = {
                    try store.transitionInstallation(
                        installationID: summary.installationID,
                        expectedStateRevision: summary.stateRevision,
                        to: destination,
                        explicitRetry: source == .failed && destination == .queued,
                        failureCode: destination == .failed ? "download.test_failure" : nil
                    )
                }
                if allowed.contains(edge) {
                    _ = try operation()
                } else {
                    try expectFailure("download.state_transition_invalid", operation)
                }
            }
        }
    }

    @Test
    func reopenedStoresUseSQLCASAndRejectDuplicateModelRevision() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "local-models.sqlite")
        let first = try LocalModelStore(fileURL: url)
        let initial = try enqueue(first, id: "first", modelID: "shared-model")
        let second = try LocalModelStore(fileURL: url)

        let winner = try first.transitionInstallation(
            installationID: initial.installationID,
            expectedStateRevision: initial.stateRevision,
            to: .downloading
        )
        #expect(winner.stateRevision == 2)
        try expectFailure("download.state_revision_conflict") {
            try second.transitionInstallation(
                installationID: initial.installationID,
                expectedStateRevision: initial.stateRevision,
                to: .downloading
            )
        }
        #expect(throws: Error.self) {
            try enqueue(second, id: "duplicate", modelID: "shared-model")
        }
    }

    @Test
    func enqueueRollbackAndResumeBlobAreTransactionalAndOpaquePublicly() throws {
        let store = try LocalModelStore.inMemory()
        store.failNextEnqueueAfterInstallationForTesting()
        try expectFailure("download.injected_persistence_failure") {
            try enqueue(store, id: "rolled-back", modelID: "rollback-model")
        }
        #expect(try store.installationSummary(installationID: "rolled-back") == nil)
        #expect(store.queueCountForTesting() == 0)

        let summary = try enqueue(store, id: "blob", modelID: "blob-model")
        try store.recordArtifact(
            installationID: summary.installationID,
            artifactID: "weights",
            relativePath: "model.gguf",
            downloadURL: URL(string: "https://example.com/model.gguf")!,
            expectedBytes: 100,
            artifactSHA256: String(repeating: "a", count: 64)
        )
        let resume = Data([0, 255, 17, 0, 42])
        _ = try store.updateArtifactProgress(
            installationID: summary.installationID,
            artifactID: "weights",
            expectedStateRevision: 1,
            receivedBytes: 37,
            resumeData: resume
        )
        let storedArtifact = try store.artifactRecord(
            installationID: summary.installationID,
            artifactID: "weights"
        )
        let record = try #require(storedArtifact)
        #expect(record.resumeData == resume)
        #expect(record.receivedBytes == 37)
        _ = try store.updateArtifactProgress(
            installationID: summary.installationID,
            artifactID: "weights",
            expectedStateRevision: record.stateRevision,
            receivedBytes: 37,
            resumeData: Data()
        )
        #expect(try store.artifactRecord(
            installationID: summary.installationID,
            artifactID: "weights"
        )?.resumeData == Data())

        let publicJSON = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        #expect(!publicJSON.contains("model.gguf"))
        #expect(!publicJSON.contains("https://"))
        #expect(!publicJSON.contains(String(repeating: "a", count: 64)))
        #expect(!publicJSON.contains("root_path"))
    }

    @Test
    func queueReservationFilesystemIntentAndUseLeaseHaveCASBoundaries() throws {
        let store = try LocalModelStore.inMemory()
        _ = try enqueue(store, id: "queue-a", modelID: "queue-model-a")
        _ = try enqueue(store, id: "queue-b", modelID: "queue-model-b")
        #expect(try store.queuedInstallations() == [
            LocalDownloadQueueEntry(installationID: "queue-a", position: 0),
            LocalDownloadQueueEntry(installationID: "queue-b", position: 1),
        ])
        try expectFailure("download.state_revision_conflict") {
            try store.removeQueuedInstallation(installationID: "queue-a", expectedPosition: 1)
        }
        try store.removeQueuedInstallation(installationID: "queue-a", expectedPosition: 0)

        _ = try store.createDiskReservation(
            reservationID: "reservation-a",
            installationID: "queue-b",
            reservedBytes: 512
        )
        #expect(try store.totalReservedBytes() == 512)

        let operation = try store.createFilesystemOperation(
            operationID: "operation-a",
            installationID: "queue-b",
            kind: .cancelDownload,
            taskIdentifier: 42,
            reservationID: "reservation-a"
        )
        #expect(operation.state == .pending)
        #expect(try store.unfinishedFilesystemOperations() == [operation])
        try expectFailure("download.filesystem_operation_transition_invalid") {
            try store.transitionFilesystemOperation(
                operationID: operation.operationID,
                from: .pending,
                to: .committed
            )
        }
        try store.transitionFilesystemOperation(
            operationID: operation.operationID,
            from: .pending,
            to: .filesystemApplied
        )
        try store.transitionFilesystemOperation(
            operationID: operation.operationID,
            from: .filesystemApplied,
            to: .committed
        )
        #expect(try store.unfinishedFilesystemOperations().isEmpty)

        let storedInstallable = try store.installationSummary(installationID: "queue-b")
        var installable = try #require(storedInstallable)
        installable = try store.transitionInstallation(
            installationID: "queue-b",
            expectedStateRevision: installable.stateRevision,
            to: .downloading
        )
        installable = try store.transitionInstallation(
            installationID: "queue-b",
            expectedStateRevision: installable.stateRevision,
            to: .verifying
        )
        _ = try store.transitionInstallation(
            installationID: "queue-b",
            expectedStateRevision: installable.stateRevision,
            to: .installed
        )

        let epoch = try HostProcessEpoch.generate()
        let lease = LocalModelUseLease(
            leaseID: "lease-a",
            installationID: "queue-b",
            purpose: .loaded,
            hostProcessEpoch: epoch,
            state: .active,
            leaseRevision: 1
        )
        try store.acquireModelUseLease(lease)
        let sessionLease = LocalModelUseLease(
            leaseID: "lease-session",
            installationID: "queue-b",
            purpose: .activeSession,
            hostProcessEpoch: epoch,
            state: .active,
            leaseRevision: 1
        )
        try store.acquireModelUseLease(sessionLease)
        try expectFailure("runtime.local_model_busy") {
            try store.acquireModelUseLease(LocalModelUseLease(
                leaseID: "lease-b",
                installationID: "queue-b",
                purpose: .loaded,
                hostProcessEpoch: epoch,
                state: .active,
                leaseRevision: 1
            ))
        }
        try store.releaseModelUseLease(leaseID: lease.leaseID)
        try store.releaseModelUseLease(leaseID: sessionLease.leaseID)
        try store.releaseDiskReservation(reservationID: "reservation-a")
        #expect(try store.totalReservedBytes() == 0)
    }

    @Test
    func catalogAcceptanceIsMonotonicAtomicAndReverifiedOnReopen() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "local-models.sqlite")
        let keyRing = try combinedCatalogKeyRing()
        let production = try OfficialModelCatalogResources.loadBundled()
        let valid = try fixture("catalog-valid.json")
        let rollback = try fixture("catalog-rollback.json")
        let store = try LocalModelStore(fileURL: url)
        let service = OfficialModelCatalogService(store: store, keyRing: keyRing)

        let bundled = try service.accept(bundled: production.envelope, remote: nil)
        #expect(bundled.verified.catalogRevision == 1)
        #expect(bundled.source == .bundled)

        let remote = try service.accept(bundled: production.envelope, remote: valid)
        #expect(remote.verified.catalogRevision == 2)
        #expect(remote.source == .remote)

        let reopened = OfficialModelCatalogService(
            store: try LocalModelStore(fileURL: url),
            keyRing: keyRing
        )
        let persisted = try reopened.accept(
            bundled: production.envelope,
            remote: Data("not-json".utf8)
        )
        #expect(persisted.verified.catalogRevision == 2)
        #expect(persisted.source == .persisted)

        let idempotent = try reopened.accept(bundled: rollback, remote: valid)
        #expect(idempotent.verified.catalogRevision == 2)
        #expect(idempotent.acceptedAt == persisted.acceptedAt)

        try expectFailure("download.catalog_revision_rollback") {
            try reopened.accept(bundled: rollback, remote: production.envelope)
        }
    }

    @Test
    func equalRevisionConflictCrashRollbackAndCorruptPersistedStateFailClosed() throws {
        let keyRing = try combinedCatalogKeyRing()
        let production = try OfficialModelCatalogResources.loadBundled()
        let rollback = try fixture("catalog-rollback.json")
        let valid = try fixture("catalog-valid.json")

        let conflictStore = try LocalModelStore.inMemory()
        let conflictService = OfficialModelCatalogService(store: conflictStore, keyRing: keyRing)
        _ = try conflictService.accept(bundled: production.envelope, remote: nil)
        try expectFailure("download.catalog_revision_conflict") {
            try conflictService.accept(bundled: production.envelope, remote: rollback)
        }

        let crashStore = try LocalModelStore.inMemory()
        crashStore.failNextCatalogAcceptanceForTesting()
        let crashService = OfficialModelCatalogService(store: crashStore, keyRing: keyRing)
        try expectFailure("download.injected_persistence_failure") {
            try crashService.accept(bundled: production.envelope, remote: nil)
        }
        #expect(try crashStore.readCatalogState() == nil)

        _ = try crashService.accept(bundled: production.envelope, remote: nil)
        crashStore.failNextCatalogAcceptanceForTesting()
        try expectFailure("download.injected_persistence_failure") {
            try crashService.accept(bundled: production.envelope, remote: valid)
        }
        #expect(try crashStore.readCatalogState()?.acceptedRevision == 1)

        try crashStore.corruptCatalogKeyIDForTesting("unknown-key")
        let reopened = OfficialModelCatalogService(store: crashStore, keyRing: keyRing)
        try expectFailure("download.catalog_state_invalid") {
            try reopened.accept(bundled: production.envelope, remote: nil)
        }

        let corruptBytesStore = try LocalModelStore.inMemory()
        let corruptBytesService = OfficialModelCatalogService(
            store: corruptBytesStore,
            keyRing: keyRing
        )
        _ = try corruptBytesService.accept(bundled: production.envelope, remote: nil)
        try corruptBytesStore.corruptCatalogCanonicalBytesForTesting(Data("not-json".utf8))
        try expectFailure("download.catalog_state_invalid") {
            try corruptBytesService.accept(bundled: production.envelope, remote: nil)
        }
    }

    @Test
    func onlyCatalogServiceMayCallThePackageAcceptanceCAS() throws {
        let sourceRoot = repositoryRoot.appending(path: "toolkit/Sources")
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ))
        var callers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("acceptVerifiedCatalog(") {
                callers.append(url.lastPathComponent)
            }
        }
        #expect(callers.sorted() == ["LocalModelStore.swift", "OfficialModelCatalogService.swift"])
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "local-model-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func enqueue(
    _ store: LocalModelStore,
    id: String,
    modelID: String
) throws -> LocalInstallationSummary {
    try store.enqueueInstallation(
        installationID: id,
        modelRevision: LocalModelRevisionID(modelID: modelID, revision: 1),
        rootPath: "/private/models/\(id)"
    )
}

private func drive(
    _ store: LocalModelStore,
    summary initial: LocalInstallationSummary,
    to target: LocalInstallationState
) throws -> LocalInstallationSummary {
    var summary = initial
    func move(_ state: LocalInstallationState, failureCode: String? = nil) throws {
        summary = try store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: state,
            failureCode: failureCode
        )
    }
    switch target {
    case .queued:
        break
    case .downloading:
        try move(.downloading)
    case .paused:
        try move(.downloading)
        try move(.paused)
    case .verifying:
        try move(.downloading)
        try move(.verifying)
    case .installed:
        try move(.downloading)
        try move(.verifying)
        try move(.installed)
    case .deleting:
        try move(.downloading)
        try move(.verifying)
        try move(.installed)
        try move(.deleting)
    case .failed:
        try move(.failed, failureCode: "download.test_failure")
    }
    return summary
}

private func fixture(_ name: String) throws -> Data {
    let stem = String(name.dropLast(".json".count))
    let url = try #require(Bundle.module.url(forResource: stem, withExtension: "json"))
    return try Data(contentsOf: url)
}

private func combinedCatalogKeyRing() throws -> Data {
    let production = try OfficialModelCatalogResources.loadBundled()
    let productionObject = try #require(
        JSONSerialization.jsonObject(with: production.keyRing) as? [String: Any]
    )
    var keys = try #require(productionObject["keys"] as? [[String: Any]])
    let testKeyURL = try #require(Bundle.module.url(
        forResource: "catalog-test-public-key",
        withExtension: "txt"
    ))
    let testKey = try String(contentsOf: testKeyURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    keys.append([
        "key_id": "test-local-catalog-key",
        "public_key": testKey,
        "status": "active",
    ])
    return try JSONSerialization.data(withJSONObject: ["schema_version": "1", "keys": keys])
}

private func expectFailure<T>(_ code: String, _ operation: () throws -> T) throws {
    do {
        _ = try operation()
        Issue.record("expected LLMFailure \(code)")
    } catch let error as LLMFailure {
        #expect(error.code == code)
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private final class RecordingBackupExclusion: LocalBackupExclusionApplying, @unchecked Sendable {
    private(set) var urls: [URL] = []

    func excludeFromBackup(_ urls: [URL]) throws {
        self.urls.append(contentsOf: urls)
    }
}
