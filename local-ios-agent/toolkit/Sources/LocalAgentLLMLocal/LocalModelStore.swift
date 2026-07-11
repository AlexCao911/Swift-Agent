import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public enum LocalInstallationState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case downloading
    case paused
    case verifying
    case installed
    case deleting
    case failed
}

public struct LocalInstallationSummary: Codable, Equatable, Sendable {
    public let installationID: String
    public let modelRevision: LocalModelRevisionID
    public let state: LocalInstallationState
    public let stateRevision: UInt64
    public let failureCode: String?
}

package struct LocalInstallationRecord: Sendable {
    let installationID: String
    let modelRevision: LocalModelRevisionID
    let state: LocalInstallationState
    let stateRevision: UInt64
    let rootPath: String
    let failureCode: String?

    var summary: LocalInstallationSummary {
        LocalInstallationSummary(
            installationID: installationID,
            modelRevision: modelRevision,
            state: state,
            stateRevision: stateRevision,
            failureCode: failureCode
        )
    }
}

package struct LocalArtifactRecord: Equatable, Sendable {
    let installationID: String
    let artifactID: String
    let relativePath: String
    let downloadURL: String
    let expectedBytes: UInt64
    let receivedBytes: UInt64
    let artifactSHA256: String
    let resumeData: Data?
    let stateRevision: UInt64
}

package struct LocalDownloadQueueEntry: Equatable, Sendable {
    let installationID: String
    let position: Int64
}

package struct LocalDiskReservationRecord: Equatable, Sendable {
    let reservationID: String
    let installationID: String
    let reservedBytes: UInt64
}

package enum LocalFilesystemOperationKind: String, Equatable, Sendable {
    case promoteInstallation = "promote_installation"
    case cancelDownload = "cancel_download"
    case deleteInstallation = "delete_installation"
}

package enum LocalFilesystemOperationState: String, Equatable, Sendable {
    case pending
    case filesystemApplied = "filesystem_applied"
    case committed
}

package struct LocalFilesystemOperationRecord: Equatable, Sendable {
    let operationID: String
    let installationID: String
    let kind: LocalFilesystemOperationKind
    let state: LocalFilesystemOperationState
    let taskIdentifier: Int?
    let reservationID: String?
}

package struct LocalModelUseLease: Equatable, Sendable {
    let leaseID: String
    let installationID: String
    let hostProcessEpoch: String
    let sessionHandle: String
}

package struct StoredLocalCatalogState: Sendable {
    let acceptedRevision: UInt64
    let canonicalSignedBytes: Data
    let signature: Data
    let keyID: String
    let acceptedAt: Date
}

public struct AcceptedLocalModelCatalog: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable { case bundled, remote, persisted }
    public let verified: VerifiedLocalModelCatalog
    public let source: Source
    public let acceptedAt: Date

    public init(
        verified: VerifiedLocalModelCatalog,
        source: Source,
        acceptedAt: Date
    ) {
        self.verified = verified
        self.source = source
        self.acceptedAt = acceptedAt
    }
}

package protocol LocalBackupExclusionApplying: Sendable {
    func excludeFromBackup(_ urls: [URL]) throws
}

private struct SystemLocalBackupExclusion: LocalBackupExclusionApplying {
    func excludeFromBackup(_ urls: [URL]) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        for url in urls {
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
    }
}

public final class LocalModelStore: @unchecked Sendable {
    public let fileURL: URL

    private let database: SQLiteConnection
    private let lock = NSLock()
    private var failNextEnqueue = false
    private var failNextCatalogAcceptance = false

    public convenience init(fileURL: URL) throws {
        try self.init(
            fileURL: fileURL,
            sqlitePath: fileURL.path,
            backupExclusion: SystemLocalBackupExclusion()
        )
    }

    package convenience init(
        fileURL: URL,
        backupExclusion: any LocalBackupExclusionApplying
    ) throws {
        try self.init(
            fileURL: fileURL,
            sqlitePath: fileURL.path,
            backupExclusion: backupExclusion
        )
    }

    private init(
        fileURL: URL,
        sqlitePath: String,
        backupExclusion: any LocalBackupExclusionApplying
    ) throws {
        self.fileURL = fileURL
        if sqlitePath != ":memory:" {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        database = try SQLiteConnection(path: sqlitePath)
        _ = try database.queryRows("PRAGMA journal_mode = WAL")
        try Self.migrate(database)
        if sqlitePath != ":memory:" {
            try backupExclusion.excludeFromBackup(
                Self.reconstructableStorageURLs(fileURL: fileURL)
            )
        }
    }

    public static func `default`(appSupportRoot: URL) throws -> LocalModelStore {
        try `default`(
            appSupportRoot: appSupportRoot,
            backupExclusion: SystemLocalBackupExclusion()
        )
    }

    package static func `default`(
        appSupportRoot: URL,
        backupExclusion: any LocalBackupExclusionApplying
    ) throws -> LocalModelStore {
        try LocalModelStore(
            fileURL: appSupportRoot.appending(path: "LocalAgent/LLM/local-models.sqlite"),
            backupExclusion: backupExclusion
        )
    }

    public static func inMemory() throws -> LocalModelStore {
        try LocalModelStore(
            fileURL: URL(fileURLWithPath: ":memory:"),
            sqlitePath: ":memory:",
            backupExclusion: SystemLocalBackupExclusion()
        )
    }

    @discardableResult
    package func enqueueInstallation(
        installationID: String,
        modelRevision: LocalModelRevisionID,
        rootPath: String
    ) throws -> LocalInstallationSummary {
        try lock.withLock {
            guard !installationID.isEmpty, !modelRevision.modelID.isEmpty,
                  modelRevision.revision > 0, rootPath.hasPrefix("/")
            else { throw storeFailure("download.installation_invalid", "installation identity is invalid") }
            do {
                return try database.transaction {
                    if let existing = try installationUnlocked(installationID) {
                        guard existing.modelRevision == modelRevision,
                              existing.state == .queued
                        else {
                            throw storeFailure(
                                "download.installation_conflict",
                                "installation ID is already bound to another lifecycle"
                            )
                        }
                        return existing.summary
                    }
                    try database.execute(
                        """
                        INSERT INTO local_installations(
                          installation_id, model_id, model_revision, state,
                          state_revision, root_path, failure_code
                        ) VALUES (?1, ?2, ?3, 'queued', 1, ?4, NULL)
                        """,
                        bindings: [
                            .text(installationID), .text(modelRevision.modelID),
                            .text(String(modelRevision.revision)), .text(rootPath),
                        ]
                    )
                    if failNextEnqueue {
                        failNextEnqueue = false
                        throw storeFailure(
                            "download.injected_persistence_failure",
                            "injected failure after installation insert"
                        )
                    }
                    let next = try database.queryRows(
                        "SELECT COALESCE(MAX(queue_position), -1) + 1 AS next_position FROM local_download_queue"
                    ).first?.integer("next_position") ?? 0
                    try database.execute(
                        "INSERT INTO local_download_queue(installation_id, queue_position, enqueued_at) VALUES (?1, ?2, ?3)",
                        bindings: [
                            .text(installationID), .integer(next),
                            .text(Self.timestamp(Date())),
                        ]
                    )
                    return try requiredInstallationUnlocked(installationID).summary
                }
            } catch let error as LLMFailure {
                throw error
            } catch {
                throw storeFailure("download.store_write_failed", "could not enqueue local model installation")
            }
        }
    }

    @discardableResult
    package func transitionInstallation(
        installationID: String,
        expectedStateRevision: UInt64,
        to newState: LocalInstallationState,
        explicitRetry: Bool = false,
        failureCode: String? = nil
    ) throws -> LocalInstallationSummary {
        try lock.withLock {
            let current = try requiredInstallationUnlocked(installationID)
            guard current.stateRevision == expectedStateRevision else { throw staleState() }
            guard Self.allowsTransition(from: current.state, to: newState, explicitRetry: explicitRetry) else {
                throw storeFailure(
                    "download.state_transition_invalid",
                    "local installation state transition is not allowed"
                )
            }
            guard (newState == .failed) == (failureCode != nil) else {
                throw storeFailure(
                    "download.failure_code_invalid",
                    "failed state requires exactly one display-safe failure code"
                )
            }
            let nextRevision = try incrementStateRevision(expectedStateRevision)
            let changed = try database.executeChanges(
                """
                UPDATE local_installations
                SET state = ?1, state_revision = ?2, failure_code = ?3
                WHERE installation_id = ?4 AND state = ?5 AND state_revision = ?6
                """,
                bindings: [
                    .text(newState.rawValue), .integer(try sqliteInteger(nextRevision)),
                    failureCode.map(SQLiteValue.text) ?? .null,
                    .text(installationID), .text(current.state.rawValue),
                    .integer(try sqliteInteger(expectedStateRevision)),
                ]
            )
            guard changed == 1 else { throw staleState() }
            return try requiredInstallationUnlocked(installationID).summary
        }
    }

    package func completeDeletion(
        installationID: String,
        expectedStateRevision: UInt64
    ) throws {
        try lock.withLock {
            try database.transaction {
                let current = try requiredInstallationUnlocked(installationID)
                guard current.state == .deleting,
                      current.stateRevision == expectedStateRevision
                else { throw staleState() }
                let changed = try database.executeChanges(
                    "DELETE FROM local_installations WHERE installation_id = ?1 AND state = 'deleting' AND state_revision = ?2",
                    bindings: [.text(installationID), .integer(try sqliteInteger(expectedStateRevision))]
                )
                guard changed == 1 else { throw staleState() }
            }
        }
    }

    public func installationSummary(installationID: String) throws -> LocalInstallationSummary? {
        try lock.withLock { try installationUnlocked(installationID)?.summary }
    }

    package func installationRecord(installationID: String) throws -> LocalInstallationRecord? {
        try lock.withLock { try installationUnlocked(installationID) }
    }

    package func recordArtifact(
        installationID: String,
        artifactID: String,
        relativePath: String,
        downloadURL: URL,
        expectedBytes: UInt64,
        artifactSHA256: String
    ) throws {
        try lock.withLock {
            _ = try requiredInstallationUnlocked(installationID)
            try database.execute(
                """
                INSERT INTO local_artifacts(
                  installation_id, artifact_id, relative_path, download_url,
                  expected_bytes, received_bytes, artifact_sha256, resume_data,
                  etag, last_modified, state_revision, task_identifier
                ) VALUES (?1, ?2, ?3, ?4, ?5, '0', ?6, NULL, NULL, NULL, 1, NULL)
                """,
                bindings: [
                    .text(installationID), .text(artifactID), .text(relativePath),
                    .text(downloadURL.absoluteString), .text(String(expectedBytes)),
                    .text(artifactSHA256),
                ]
            )
        }
    }

    package func updateArtifactProgress(
        installationID: String,
        artifactID: String,
        expectedStateRevision: UInt64,
        receivedBytes: UInt64,
        resumeData: Data?
    ) throws -> UInt64 {
        try lock.withLock {
            guard let artifact = try artifactUnlocked(
                installationID: installationID,
                artifactID: artifactID
            ), receivedBytes <= artifact.expectedBytes else {
                throw storeFailure(
                    "download.artifact_progress_invalid",
                    "artifact progress exceeds its signed size"
                )
            }
            let next = try incrementStateRevision(expectedStateRevision)
            let changed = try database.executeChanges(
                """
                UPDATE local_artifacts
                SET received_bytes = ?1, resume_data = ?2, state_revision = ?3
                WHERE installation_id = ?4 AND artifact_id = ?5 AND state_revision = ?6
                """,
                bindings: [
                    .text(String(receivedBytes)), resumeData.map(SQLiteValue.blob) ?? .null,
                    .integer(try sqliteInteger(next)), .text(installationID), .text(artifactID),
                    .integer(try sqliteInteger(expectedStateRevision)),
                ]
            )
            guard changed == 1 else { throw staleState() }
            return next
        }
    }

    package func artifactRecord(
        installationID: String,
        artifactID: String
    ) throws -> LocalArtifactRecord? {
        try lock.withLock {
            try artifactUnlocked(installationID: installationID, artifactID: artifactID)
        }
    }

    package func queuedInstallations() throws -> [LocalDownloadQueueEntry] {
        try lock.withLock {
            try database.queryRows(
                "SELECT installation_id, queue_position FROM local_download_queue ORDER BY queue_position"
            ).map { row in
                guard let id = row.text("installation_id"),
                      let position = row.integer("queue_position")
                else { throw storeCorrupt() }
                return LocalDownloadQueueEntry(installationID: id, position: position)
            }
        }
    }

    package func removeQueuedInstallation(
        installationID: String,
        expectedPosition: Int64
    ) throws {
        try lock.withLock {
            let changed = try database.executeChanges(
                "DELETE FROM local_download_queue WHERE installation_id = ?1 AND queue_position = ?2",
                bindings: [.text(installationID), .integer(expectedPosition)]
            )
            guard changed == 1 else { throw staleState() }
        }
    }

    package func createDiskReservation(
        reservationID: String,
        installationID: String,
        reservedBytes: UInt64
    ) throws -> LocalDiskReservationRecord {
        try lock.withLock {
            _ = try requiredInstallationUnlocked(installationID)
            try database.execute(
                "INSERT INTO local_disk_reservations(reservation_id, installation_id, reserved_bytes, created_at) VALUES (?1, ?2, ?3, ?4)",
                bindings: [
                    .text(reservationID), .text(installationID),
                    .text(String(reservedBytes)), .text(Self.timestamp(Date())),
                ]
            )
            return LocalDiskReservationRecord(
                reservationID: reservationID,
                installationID: installationID,
                reservedBytes: reservedBytes
            )
        }
    }

    package func totalReservedBytes() throws -> UInt64 {
        try lock.withLock {
            try database.queryRows("SELECT reserved_bytes FROM local_disk_reservations")
                .reduce(0) { total, row in
                    guard let text = row.text("reserved_bytes"), let value = UInt64(text) else {
                        throw storeCorrupt()
                    }
                    let (sum, overflow) = total.addingReportingOverflow(value)
                    guard !overflow else {
                        throw storeFailure("download.reservation_overflow", "disk reservations overflow UInt64")
                    }
                    return sum
                }
        }
    }

    package func releaseDiskReservation(reservationID: String) throws {
        try lock.withLock {
            let changed = try database.executeChanges(
                "DELETE FROM local_disk_reservations WHERE reservation_id = ?1",
                bindings: [.text(reservationID)]
            )
            guard changed == 1 else { throw staleState() }
        }
    }

    package func createFilesystemOperation(
        operationID: String,
        installationID: String,
        kind: LocalFilesystemOperationKind,
        taskIdentifier: Int? = nil,
        reservationID: String? = nil
    ) throws -> LocalFilesystemOperationRecord {
        try lock.withLock {
            try database.execute(
                """
                INSERT INTO local_filesystem_operations(
                  operation_id, installation_id, kind, state, task_identifier,
                  reservation_id, created_at
                ) VALUES (?1, ?2, ?3, 'pending', ?4, ?5, ?6)
                """,
                bindings: [
                    .text(operationID), .text(installationID), .text(kind.rawValue),
                    taskIdentifier.map { .integer(Int64($0)) } ?? .null,
                    reservationID.map(SQLiteValue.text) ?? .null,
                    .text(Self.timestamp(Date())),
                ]
            )
            return LocalFilesystemOperationRecord(
                operationID: operationID,
                installationID: installationID,
                kind: kind,
                state: .pending,
                taskIdentifier: taskIdentifier,
                reservationID: reservationID
            )
        }
    }

    package func transitionFilesystemOperation(
        operationID: String,
        from expected: LocalFilesystemOperationState,
        to next: LocalFilesystemOperationState
    ) throws {
        let allowed = (expected == .pending && next == .filesystemApplied)
            || (expected == .filesystemApplied && next == .committed)
        guard allowed else {
            throw storeFailure(
                "download.filesystem_operation_transition_invalid",
                "filesystem operation transition is not allowed"
            )
        }
        try lock.withLock {
            let changed = try database.executeChanges(
                "UPDATE local_filesystem_operations SET state = ?1 WHERE operation_id = ?2 AND state = ?3",
                bindings: [.text(next.rawValue), .text(operationID), .text(expected.rawValue)]
            )
            guard changed == 1 else { throw staleState() }
        }
    }

    package func unfinishedFilesystemOperations() throws -> [LocalFilesystemOperationRecord] {
        try lock.withLock {
            try database.queryRows(
                """
                SELECT operation_id, installation_id, kind, state,
                       task_identifier, reservation_id
                FROM local_filesystem_operations
                WHERE state != 'committed' ORDER BY created_at, operation_id
                """
            ).map { row in
                guard let operationID = row.text("operation_id"),
                      let installationID = row.text("installation_id"),
                      let kindText = row.text("kind"),
                      let kind = LocalFilesystemOperationKind(rawValue: kindText),
                      let stateText = row.text("state"),
                      let state = LocalFilesystemOperationState(rawValue: stateText)
                else { throw storeCorrupt() }
                let taskIdentifier = row.integer("task_identifier").flatMap(Int.init(exactly:))
                return LocalFilesystemOperationRecord(
                    operationID: operationID,
                    installationID: installationID,
                    kind: kind,
                    state: state,
                    taskIdentifier: taskIdentifier,
                    reservationID: row.text("reservation_id")
                )
            }
        }
    }

    package func acquireModelUseLease(_ lease: LocalModelUseLease) throws {
        try lock.withLock {
            try database.transaction {
                let count = try database.queryRows(
                    "SELECT COUNT(*) AS count FROM local_model_use_leases"
                ).first?.integer("count") ?? 0
                guard count == 0 else {
                    throw storeFailure(
                        "runtime.local_model_busy",
                        "only one local model use lease may be active"
                    )
                }
                _ = try requiredInstallationUnlocked(lease.installationID)
                try database.execute(
                    """
                    INSERT INTO local_model_use_leases(
                      lease_id, installation_id, host_process_epoch, session_handle, created_at
                    ) VALUES (?1, ?2, ?3, ?4, ?5)
                    """,
                    bindings: [
                        .text(lease.leaseID), .text(lease.installationID),
                        .text(lease.hostProcessEpoch), .text(lease.sessionHandle),
                        .text(Self.timestamp(Date())),
                    ]
                )
            }
        }
    }

    package func releaseModelUseLease(leaseID: String) throws {
        try lock.withLock {
            let changed = try database.executeChanges(
                "DELETE FROM local_model_use_leases WHERE lease_id = ?1",
                bindings: [.text(leaseID)]
            )
            guard changed == 1 else { throw staleState() }
        }
    }

    package func readCatalogState() throws -> StoredLocalCatalogState? {
        try lock.withLock { try catalogStateUnlocked() }
    }

    package func acceptVerifiedCatalog(
        _ candidate: VerifiedLocalModelCatalog,
        expectedAcceptedRevision: UInt64?
    ) throws -> AcceptedLocalModelCatalog {
        try lock.withLock {
            try database.transaction {
                let current = try catalogStateUnlocked()
                guard current?.acceptedRevision == expectedAcceptedRevision else {
                    throw storeFailure(
                        "download.catalog_acceptance_conflict",
                        "accepted catalog changed before compare-and-swap"
                    )
                }
                if let current {
                    if candidate.catalogRevision < current.acceptedRevision {
                        throw storeFailure(
                            "download.catalog_revision_rollback",
                            "catalog revision is below the monotonic acceptance floor"
                        )
                    }
                    if candidate.catalogRevision == current.acceptedRevision {
                        guard candidate.canonicalSignedBytes == current.canonicalSignedBytes,
                              candidate.signature == current.signature,
                              candidate.keyID == current.keyID
                        else {
                            throw storeFailure(
                                "download.catalog_revision_conflict",
                                "equal catalog revision has different signed content"
                            )
                        }
                        return AcceptedLocalModelCatalog(
                            verified: candidate,
                            source: .persisted,
                            acceptedAt: current.acceptedAt
                        )
                    }
                }

                let acceptedAt = Date()
                if current == nil {
                    try database.execute(
                        """
                        INSERT INTO local_catalog_state(
                          singleton_id, accepted_revision, canonical_signed_bytes,
                          signature, key_id, accepted_at
                        ) VALUES (1, ?1, ?2, ?3, ?4, ?5)
                        """,
                        bindings: [
                            .text(String(candidate.catalogRevision)),
                            .blob(candidate.canonicalSignedBytes), .blob(candidate.signature),
                            .text(candidate.keyID), .text(Self.timestamp(acceptedAt)),
                        ]
                    )
                } else {
                    let changed = try database.executeChanges(
                        """
                        UPDATE local_catalog_state
                        SET accepted_revision = ?1, canonical_signed_bytes = ?2,
                            signature = ?3, key_id = ?4, accepted_at = ?5
                        WHERE singleton_id = 1 AND accepted_revision = ?6
                        """,
                        bindings: [
                            .text(String(candidate.catalogRevision)),
                            .blob(candidate.canonicalSignedBytes), .blob(candidate.signature),
                            .text(candidate.keyID), .text(Self.timestamp(acceptedAt)),
                            .text(String(try required(expectedAcceptedRevision))),
                        ]
                    )
                    guard changed == 1 else {
                        throw storeFailure(
                            "download.catalog_acceptance_conflict",
                            "accepted catalog changed before update"
                        )
                    }
                }
                if failNextCatalogAcceptance {
                    failNextCatalogAcceptance = false
                    throw storeFailure(
                        "download.injected_persistence_failure",
                        "injected catalog acceptance crash boundary"
                    )
                }
                return AcceptedLocalModelCatalog(
                    verified: candidate,
                    source: .persisted,
                    acceptedAt: acceptedAt
                )
            }
        }
    }

    package func failNextEnqueueAfterInstallationForTesting() {
        lock.withLock { failNextEnqueue = true }
    }

    package func failNextCatalogAcceptanceForTesting() {
        lock.withLock { failNextCatalogAcceptance = true }
    }

    package func corruptCatalogKeyIDForTesting(_ keyID: String) throws {
        try lock.withLock {
            try database.execute(
                "UPDATE local_catalog_state SET key_id = ?1 WHERE singleton_id = 1",
                bindings: [.text(keyID)]
            )
        }
    }

    package func corruptCatalogCanonicalBytesForTesting(_ bytes: Data) throws {
        try lock.withLock {
            try database.execute(
                "UPDATE local_catalog_state SET canonical_signed_bytes = ?1 WHERE singleton_id = 1",
                bindings: [.blob(bytes)]
            )
        }
    }

    package func schemaVersionForTesting() -> UInt64 {
        lock.withLock {
            guard let value = try? database.queryRows("PRAGMA user_version").first?.integer("user_version") else {
                return 0
            }
            return UInt64(value)
        }
    }

    package func tableNamesForTesting() -> [String] {
        lock.withLock {
            (try? database.queryRows(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            ).compactMap { $0.text("name") }) ?? []
        }
    }

    package func queueCountForTesting() -> Int {
        lock.withLock {
            Int((try? database.queryRows(
                "SELECT COUNT(*) AS count FROM local_download_queue"
            ).first?.integer("count")) ?? 0)
        }
    }

    private func installationUnlocked(_ id: String) throws -> LocalInstallationRecord? {
        guard let row = try database.queryRows(
            """
            SELECT installation_id, model_id, model_revision, state,
                   state_revision, root_path, failure_code
            FROM local_installations WHERE installation_id = ?1
            """,
            bindings: [.text(id)]
        ).first else { return nil }
        guard let installationID = row.text("installation_id"),
              let modelID = row.text("model_id"),
              let revisionText = row.text("model_revision"),
              let modelRevision = UInt64(revisionText),
              let stateText = row.text("state"),
              let state = LocalInstallationState(rawValue: stateText),
              let stateRevisionValue = row.integer("state_revision"),
              let stateRevision = UInt64(exactly: stateRevisionValue),
              let rootPath = row.text("root_path")
        else { throw storeCorrupt() }
        return LocalInstallationRecord(
            installationID: installationID,
            modelRevision: LocalModelRevisionID(modelID: modelID, revision: modelRevision),
            state: state,
            stateRevision: stateRevision,
            rootPath: rootPath,
            failureCode: row.text("failure_code")
        )
    }

    private func requiredInstallationUnlocked(_ id: String) throws -> LocalInstallationRecord {
        guard let value = try installationUnlocked(id) else {
            throw storeFailure("download.installation_not_found", "local installation does not exist")
        }
        return value
    }

    private func artifactUnlocked(
        installationID: String,
        artifactID: String
    ) throws -> LocalArtifactRecord? {
        guard let row = try database.queryRows(
            """
            SELECT installation_id, artifact_id, relative_path, download_url,
                   expected_bytes, received_bytes, artifact_sha256, resume_data, state_revision
            FROM local_artifacts WHERE installation_id = ?1 AND artifact_id = ?2
            """,
            bindings: [.text(installationID), .text(artifactID)]
        ).first else { return nil }
        guard let expectedText = row.text("expected_bytes"), let expected = UInt64(expectedText),
              let receivedText = row.text("received_bytes"), let received = UInt64(receivedText),
              let revisionValue = row.integer("state_revision"),
              let revision = UInt64(exactly: revisionValue),
              let relativePath = row.text("relative_path"),
              let url = row.text("download_url"), let sha = row.text("artifact_sha256")
        else { throw storeCorrupt() }
        return LocalArtifactRecord(
            installationID: installationID,
            artifactID: artifactID,
            relativePath: relativePath,
            downloadURL: url,
            expectedBytes: expected,
            receivedBytes: received,
            artifactSHA256: sha,
            resumeData: row.blob("resume_data"),
            stateRevision: revision
        )
    }

    private func catalogStateUnlocked() throws -> StoredLocalCatalogState? {
        guard let row = try database.queryRows(
            """
            SELECT accepted_revision, canonical_signed_bytes, signature, key_id, accepted_at
            FROM local_catalog_state WHERE singleton_id = 1
            """
        ).first else { return nil }
        guard let revisionText = row.text("accepted_revision"),
              let revision = UInt64(revisionText),
              let canonical = row.blob("canonical_signed_bytes"),
              let signature = row.blob("signature"),
              let keyID = row.text("key_id"),
              let acceptedText = row.text("accepted_at"),
              let acceptedSeconds = TimeInterval(acceptedText)
        else { throw storeCorrupt() }
        return StoredLocalCatalogState(
            acceptedRevision: revision,
            canonicalSignedBytes: canonical,
            signature: signature,
            keyID: keyID,
            acceptedAt: Date(timeIntervalSince1970: acceptedSeconds)
        )
    }

    private static func allowsTransition(
        from: LocalInstallationState,
        to: LocalInstallationState,
        explicitRetry: Bool
    ) -> Bool {
        switch (from, to) {
        case (.queued, .downloading), (.queued, .failed),
             (.downloading, .paused), (.downloading, .verifying), (.downloading, .failed),
             (.paused, .downloading), (.paused, .failed),
             (.verifying, .installed), (.verifying, .failed),
             (.installed, .deleting):
            return true
        case (.failed, .queued):
            return explicitRetry
        default:
            return false
        }
    }

    private static func createSchema(_ database: SQLiteConnection) throws {
        try database.transaction {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_catalog_state(
                  singleton_id INTEGER PRIMARY KEY CHECK(singleton_id = 1),
                  accepted_revision TEXT NOT NULL,
                  canonical_signed_bytes BLOB NOT NULL,
                  signature BLOB NOT NULL,
                  key_id TEXT NOT NULL,
                  accepted_at TEXT NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_installations(
                  installation_id TEXT PRIMARY KEY,
                  model_id TEXT NOT NULL,
                  model_revision TEXT NOT NULL,
                  state TEXT NOT NULL,
                  state_revision INTEGER NOT NULL,
                  root_path TEXT NOT NULL,
                  failure_code TEXT,
                  UNIQUE(model_id, model_revision)
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_artifacts(
                  installation_id TEXT NOT NULL REFERENCES local_installations(installation_id) ON DELETE CASCADE,
                  artifact_id TEXT NOT NULL,
                  relative_path TEXT NOT NULL,
                  download_url TEXT NOT NULL,
                  expected_bytes TEXT NOT NULL,
                  received_bytes TEXT NOT NULL,
                  artifact_sha256 TEXT NOT NULL,
                  resume_data BLOB,
                  etag TEXT,
                  last_modified TEXT,
                  state_revision INTEGER NOT NULL,
                  task_identifier INTEGER,
                  PRIMARY KEY(installation_id, artifact_id)
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_download_queue(
                  installation_id TEXT PRIMARY KEY REFERENCES local_installations(installation_id) ON DELETE CASCADE,
                  queue_position INTEGER NOT NULL UNIQUE,
                  enqueued_at TEXT NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_disk_reservations(
                  reservation_id TEXT PRIMARY KEY,
                  installation_id TEXT NOT NULL REFERENCES local_installations(installation_id) ON DELETE CASCADE,
                  reserved_bytes TEXT NOT NULL,
                  created_at TEXT NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_filesystem_operations(
                  operation_id TEXT PRIMARY KEY,
                  installation_id TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  state TEXT NOT NULL,
                  task_identifier INTEGER,
                  reservation_id TEXT,
                  created_at TEXT NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS local_model_use_leases(
                  lease_id TEXT PRIMARY KEY,
                  installation_id TEXT NOT NULL REFERENCES local_installations(installation_id) ON DELETE CASCADE,
                  host_process_epoch TEXT NOT NULL,
                  session_handle TEXT NOT NULL,
                  created_at TEXT NOT NULL
                )
                """
            )
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS prepared_local_sessions(
                  preparation_id TEXT PRIMARY KEY,
                  installation_id TEXT NOT NULL,
                  target_id TEXT NOT NULL,
                  target_revision TEXT NOT NULL,
                  binding_id TEXT NOT NULL,
                  binding_revision TEXT NOT NULL,
                  binding_hash TEXT NOT NULL,
                  requirements_hash TEXT NOT NULL,
                  host_process_epoch TEXT NOT NULL,
                  state TEXT NOT NULL,
                  snapshot_blob BLOB NOT NULL
                )
                """
            )
            try database.execute("PRAGMA user_version = 1")
        }
    }

    private static func migrate(_ database: SQLiteConnection) throws {
        let version = try database.queryRows("PRAGMA user_version")
            .first?.integer("user_version") ?? 0
        guard version == 0 || version == 1 else {
            throw storeFailure(
                "download.store_schema_unsupported",
                "local model database schema is newer than this app"
            )
        }
        try createSchema(database)
    }

    private static func reconstructableStorageURLs(fileURL: URL) -> [URL] {
        var urls = [fileURL.deletingLastPathComponent()]
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: fileURL.path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                urls.append(candidate)
            }
        }
        return urls
    }

    private static func timestamp(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }
}

private func sqliteInteger(_ value: UInt64) throws -> Int64 {
    guard let result = Int64(exactly: value) else {
        throw storeFailure("download.sqlite_integer_overflow", "state revision exceeds SQLite range")
    }
    return result
}

private func incrementStateRevision(_ value: UInt64) throws -> UInt64 {
    let (next, overflow) = value.addingReportingOverflow(1)
    guard !overflow else {
        throw storeFailure("download.state_revision_overflow", "state revision cannot advance")
    }
    return next
}

private func required<T>(_ value: T?) throws -> T {
    guard let value else { throw storeCorrupt() }
    return value
}

private func storeFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}

private func staleState() -> LLMFailure {
    storeFailure("download.state_revision_conflict", "local installation state revision is stale")
}

private func storeCorrupt() -> LLMFailure {
    storeFailure("download.store_corrupt", "local model SQLite state is corrupt")
}
