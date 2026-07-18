import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Security

public struct PreparedCloudSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let preparationID: String
    public let proposedRunID: String
    public let targetID: LLMTargetID
    public let targetRevision: UInt64
    public let bindingID: String
    public let bindingRevision: UInt64
    public let bindingHash: String
    public let requirementsHash: String
    public let providerProfileID: String
    public let providerProfileRevision: UInt64
    public let origin: EgressOrigin
    public let credentialRef: String
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let credentialUseLeaseID: String
    public let credentialUseLeaseDigest: String
    public let modelID: String
    public let capabilitySnapshotDigest: String
    public let resolvedParametersDigest: String
    public let initialDisclosureDigest: String
    public let scopeGrantID: String
    public let generationAuthorizationID: String
    public let opaqueEgressSubjectDigest: String
    public let egressAttestationDigest: String
    public let hostProcessEpoch: HostProcessEpoch
    public let adapterID: String
    public let adapterVersion: String

    public init(
        sessionID: String,
        preparationID: String,
        proposedRunID: String,
        targetID: LLMTargetID,
        targetRevision: UInt64,
        bindingID: String,
        bindingRevision: UInt64,
        bindingHash: String,
        requirementsHash: String,
        providerProfileID: String,
        providerProfileRevision: UInt64,
        origin: EgressOrigin,
        credentialRef: String,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?,
        credentialUseLeaseID: String,
        credentialUseLeaseDigest: String,
        modelID: String,
        capabilitySnapshotDigest: String,
        resolvedParametersDigest: String,
        initialDisclosureDigest: String,
        scopeGrantID: String,
        generationAuthorizationID: String,
        opaqueEgressSubjectDigest: String,
        egressAttestationDigest: String,
        hostProcessEpoch: HostProcessEpoch,
        adapterID: String,
        adapterVersion: String
    ) {
        self.sessionID = sessionID
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.targetID = targetID
        self.targetRevision = targetRevision
        self.bindingID = bindingID
        self.bindingRevision = bindingRevision
        self.bindingHash = bindingHash
        self.requirementsHash = requirementsHash
        self.providerProfileID = providerProfileID
        self.providerProfileRevision = providerProfileRevision
        self.origin = origin
        self.credentialRef = credentialRef
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.credentialUseLeaseID = credentialUseLeaseID
        self.credentialUseLeaseDigest = credentialUseLeaseDigest
        self.modelID = modelID
        self.capabilitySnapshotDigest = capabilitySnapshotDigest
        self.resolvedParametersDigest = resolvedParametersDigest
        self.initialDisclosureDigest = initialDisclosureDigest
        self.scopeGrantID = scopeGrantID
        self.generationAuthorizationID = generationAuthorizationID
        self.opaqueEgressSubjectDigest = opaqueEgressSubjectDigest
        self.egressAttestationDigest = egressAttestationDigest
        self.hostProcessEpoch = hostProcessEpoch
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
    }

    package static func generateSessionID() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw cloudSessionFailure(
                "runtime.cloud_random_generation_failed",
                "could not generate a cloud session identity"
            )
        }
        return CloudBase64URL.encode(Data(bytes))
    }
}

package struct SanitizedCloudSessionSnapshot: Codable, Equatable, Sendable {
    package let snapshotID: String
    package let sessionID: String
    package let runID: String
    package let preparationID: String
    package let hostProcessEpoch: HostProcessEpoch
    package let capabilitySnapshot: CapabilitySnapshot
    package let resolvedConfiguration: GenerationConfiguration

    package init(
        snapshotID: String,
        sessionID: String,
        runID: String,
        preparationID: String,
        hostProcessEpoch: HostProcessEpoch,
        capabilitySnapshot: CapabilitySnapshot,
        resolvedConfiguration: GenerationConfiguration
    ) {
        self.snapshotID = snapshotID
        self.sessionID = sessionID
        self.runID = runID
        self.preparationID = preparationID
        self.hostProcessEpoch = hostProcessEpoch
        self.capabilitySnapshot = capabilitySnapshot
        self.resolvedConfiguration = resolvedConfiguration
    }
}

package enum PreparedCloudSessionLifecycle: String, Codable, Equatable, Sendable {
    case prepared
    case generating
    case awaitingToolResult = "awaiting_tool_result"
    case terminal
    case quarantined
    case closed
}

package struct StoredPreparedCloudSession: Equatable, Sendable {
    package let session: PreparedCloudSession
    package let lifecycle: PreparedCloudSessionLifecycle
}

package enum CloudSessionCloseDisposition: String, Codable, Equatable, Sendable {
    case closed
    case epochEnded = "epoch_ended"
    case interrupted
}

package struct CloudSessionTombstone: Codable, Equatable, Sendable {
    package let sessionID: String
    package let closeRevision: UInt64
    package let disposition: CloudSessionCloseDisposition
    package let hostProcessEpoch: HostProcessEpoch
    package let closedAt: Date
}

package final class PreparedCloudSessionStore: @unchecked Sendable {
    private struct SessionRecord: Codable {
        let recordSchemaVersion: Int
        let session: PreparedCloudSession
        var lifecycle: PreparedCloudSessionLifecycle
    }

    private struct SnapshotRecord: Codable {
        let recordSchemaVersion: Int
        let snapshot: SanitizedCloudSessionSnapshot
    }

    private struct TombstoneRecord: Codable {
        let recordSchemaVersion: Int
        let tombstone: CloudSessionTombstone
    }

    private let database: SQLiteConnection

    package init(fileURL: URL) throws {
        database = try SQLiteConnection(path: fileURL.path)
        try LLMStoreSchema.ensureBaseSchema(database)
        try LLMStoreSchema.migrateToVersionTwo(database)
    }

    package func persistPreparedSession(
        _ session: PreparedCloudSession,
        snapshot: SanitizedCloudSessionSnapshot,
        credentialLease: CredentialUseLease
    ) throws {
        try validate(session: session, snapshot: snapshot, lease: credentialLease)
        try database.transaction {
            let leaseRows = try database.queryRows(
                """
                SELECT credential_ref, generation, purpose, preparation_id, host_epoch,
                  lifecycle, revision, record_schema_version
                FROM credential_use_leases WHERE lease_id = ?1
                """,
                bindings: [.text(credentialLease.leaseID)]
            )
            guard leaseRows.count == 1,
                  leaseRows[0].integer("record_schema_version") == 2,
                  leaseRows[0].text("credential_ref") == credentialLease.credentialRef,
                  leaseRows[0].text("generation") == String(credentialLease.generation),
                  leaseRows[0].text("purpose") == CredentialUsePurpose.preparation.rawValue,
                  leaseRows[0].text("preparation_id") == credentialLease.preparationID,
                  leaseRows[0].text("host_epoch") == credentialLease.hostProcessEpoch.rawValue,
                  leaseRows[0].text("lifecycle") == CredentialUseLifecycle.acquired.rawValue,
                  leaseRows[0].text("revision") == String(credentialLease.revision)
            else {
                throw cloudSessionFailure(
                    "runtime.cloud_credential_lease_invalid",
                    "prepared cloud session lease is missing or changed"
                )
            }
            try database.execute(
                """
                INSERT INTO prepared_cloud_sessions(
                  session_id, preparation_id, proposed_run_id, host_epoch, lifecycle,
                  record_schema_version, record_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, 2, ?6)
                """,
                bindings: [
                    .text(session.sessionID), .text(session.preparationID),
                    .text(session.proposedRunID), .text(session.hostProcessEpoch.rawValue),
                    .text(PreparedCloudSessionLifecycle.prepared.rawValue),
                    .text(try encode(SessionRecord(
                        recordSchemaVersion: 2,
                        session: session,
                        lifecycle: .prepared
                    ))),
                ]
            )
            try database.execute(
                """
                INSERT INTO sanitized_llm_snapshots(
                  snapshot_id, run_id, preparation_id, host_epoch,
                  record_schema_version, record_json
                ) VALUES (?1, ?2, ?3, ?4, 2, ?5)
                """,
                bindings: [
                    .text(snapshot.snapshotID), .text(snapshot.runID),
                    .text(snapshot.preparationID), .text(snapshot.hostProcessEpoch.rawValue),
                    .text(try encode(SnapshotRecord(recordSchemaVersion: 2, snapshot: snapshot))),
                ]
            )
        }
    }

    package func session(_ sessionID: String) throws -> StoredPreparedCloudSession? {
        let rows = try database.queryRows(
            """
            SELECT preparation_id, proposed_run_id, host_epoch, lifecycle,
              record_schema_version, record_json
            FROM prepared_cloud_sessions WHERE session_id = ?1
            """,
            bindings: [.text(sessionID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptSession("prepared cloud session") }
        let record = try decode(SessionRecord.self, json)
        guard record.recordSchemaVersion == 2,
              record.session.sessionID == sessionID,
              row.text("preparation_id") == record.session.preparationID,
              row.text("proposed_run_id") == record.session.proposedRunID,
              row.text("host_epoch") == record.session.hostProcessEpoch.rawValue,
              row.text("lifecycle") == record.lifecycle.rawValue
        else { throw corruptSession("prepared cloud session index") }
        return StoredPreparedCloudSession(session: record.session, lifecycle: record.lifecycle)
    }

    package func snapshot(_ snapshotID: String) throws -> SanitizedCloudSessionSnapshot? {
        let rows = try database.queryRows(
            """
            SELECT run_id, preparation_id, host_epoch, record_schema_version, record_json
            FROM sanitized_llm_snapshots WHERE snapshot_id = ?1
            """,
            bindings: [.text(snapshotID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptSession("sanitized cloud snapshot") }
        let record = try decode(SnapshotRecord.self, json)
        guard record.recordSchemaVersion == 2,
              record.snapshot.snapshotID == snapshotID,
              row.text("run_id") == record.snapshot.runID,
              row.text("preparation_id") == record.snapshot.preparationID,
              row.text("host_epoch") == record.snapshot.hostProcessEpoch.rawValue
        else { throw corruptSession("sanitized cloud snapshot index") }
        return record.snapshot
    }

    package func transition(
        sessionID: String,
        from expected: PreparedCloudSessionLifecycle,
        to next: PreparedCloudSessionLifecycle
    ) throws {
        guard let stored = try session(sessionID) else {
            throw cloudSessionFailure("runtime.cloud_session_not_found", "cloud session was not found")
        }
        guard stored.lifecycle == expected else {
            throw cloudSessionFailure("runtime.cloud_session_state_conflict", "cloud session state changed")
        }
        let record = SessionRecord(
            recordSchemaVersion: 2,
            session: stored.session,
            lifecycle: next
        )
        let changed = try database.executeChanges(
            """
            UPDATE prepared_cloud_sessions SET lifecycle = ?1, record_json = ?2
            WHERE session_id = ?3 AND lifecycle = ?4
            """,
            bindings: [
                .text(next.rawValue), .text(try encode(record)),
                .text(sessionID), .text(expected.rawValue),
            ]
        )
        guard changed == 1 else {
            throw cloudSessionFailure("runtime.cloud_session_state_conflict", "cloud session state changed")
        }
    }

    package func abortBeforeSessionBinding(
        sessionID: String,
        expectedLeaseRevision: UInt64
    ) throws {
        try database.transaction {
            guard let stored = try session(sessionID), stored.lifecycle == .prepared else {
                throw cloudSessionFailure(
                    "runtime.cloud_session_state_conflict",
                    "prepared cloud session changed before abort"
                )
            }
            let leaseRows = try database.queryRows(
                """
                SELECT lifecycle, revision FROM credential_use_leases WHERE lease_id = ?1
                """,
                bindings: [.text(stored.session.credentialUseLeaseID)]
            )
            guard leaseRows.count == 1,
                  leaseRows[0].text("lifecycle") == CredentialUseLifecycle.acquired.rawValue,
                  leaseRows[0].text("revision") == String(expectedLeaseRevision)
            else {
                throw cloudSessionFailure(
                    "runtime.cloud_credential_lease_invalid",
                    "preparation lease changed before abort"
                )
            }
            let removedSnapshot = try database.executeChanges(
                "DELETE FROM sanitized_llm_snapshots WHERE preparation_id = ?1 AND host_epoch = ?2",
                bindings: [
                    .text(stored.session.preparationID),
                    .text(stored.session.hostProcessEpoch.rawValue),
                ]
            )
            let removedSession = try database.executeChanges(
                "DELETE FROM prepared_cloud_sessions WHERE session_id = ?1 AND lifecycle = 'prepared'",
                bindings: [.text(sessionID)]
            )
            let removedLease = try database.executeChanges(
                """
                DELETE FROM credential_use_leases
                WHERE lease_id = ?1 AND lifecycle = 'acquired' AND revision = ?2
                """,
                bindings: [
                    .text(stored.session.credentialUseLeaseID),
                    .text(String(expectedLeaseRevision)),
                ]
            )
            guard removedSnapshot == 1, removedSession == 1, removedLease == 1 else {
                throw cloudSessionFailure(
                    "runtime.cloud_session_state_conflict",
                    "prepared cloud session could not be aborted atomically"
                )
            }
        }
    }

    package func closePreparedSession(
        sessionID: String,
        expectedLifecycle: PreparedCloudSessionLifecycle,
        closingLeaseRevision: UInt64,
        disposition: CloudSessionCloseDisposition,
        now: Date = Date()
    ) throws -> CloudSessionTombstone {
        try database.transaction {
            guard let stored = try session(sessionID) else {
                throw cloudSessionFailure("runtime.cloud_session_not_found", "cloud session was not found")
            }
            if stored.lifecycle == .closed, let existing = try tombstone(sessionID) {
                return existing
            }
            guard stored.lifecycle == expectedLifecycle else {
                throw cloudSessionFailure("runtime.cloud_session_state_conflict", "cloud session state changed")
            }
            let leaseRows = try database.queryRows(
                """
                SELECT revision, lifecycle FROM credential_use_leases WHERE lease_id = ?1
                """,
                bindings: [.text(stored.session.credentialUseLeaseID)]
            )
            guard leaseRows.count == 1,
                  leaseRows[0].text("revision") == String(closingLeaseRevision),
                  leaseRows[0].text("lifecycle") == CredentialUseLifecycle.closing.rawValue
            else {
                throw cloudSessionFailure(
                    "runtime.cloud_credential_lease_invalid",
                    "cloud session closing lease is missing or changed"
                )
            }
            let closedRecord = SessionRecord(
                recordSchemaVersion: 2,
                session: stored.session,
                lifecycle: .closed
            )
            let changed = try database.executeChanges(
                """
                UPDATE prepared_cloud_sessions SET lifecycle = 'closed', record_json = ?1
                WHERE session_id = ?2 AND lifecycle = ?3
                """,
                bindings: [
                    .text(try encode(closedRecord)), .text(sessionID),
                    .text(expectedLifecycle.rawValue),
                ]
            )
            guard changed == 1 else {
                throw cloudSessionFailure("runtime.cloud_session_state_conflict", "cloud session state changed")
            }
            let tombstone = CloudSessionTombstone(
                sessionID: sessionID,
                closeRevision: 1,
                disposition: disposition,
                hostProcessEpoch: stored.session.hostProcessEpoch,
                closedAt: now
            )
            try insertTombstone(tombstone)
            let removed = try database.executeChanges(
                """
                DELETE FROM credential_use_leases
                WHERE lease_id = ?1 AND lifecycle = 'closing' AND revision = ?2
                """,
                bindings: [
                    .text(stored.session.credentialUseLeaseID),
                    .text(String(closingLeaseRevision)),
                ]
            )
            guard removed == 1 else {
                throw cloudSessionFailure(
                    "runtime.cloud_credential_lease_invalid",
                    "cloud session closing lease could not be released"
                )
            }
            return tombstone
        }
    }

    package func recoverOldEpoch(_ current: HostProcessEpoch, now: Date = Date()) throws -> Int {
        try database.transaction {
            let rows = try database.queryRows(
                """
                SELECT session_id FROM prepared_cloud_sessions
                WHERE host_epoch <> ?1 AND lifecycle <> 'closed'
                ORDER BY session_id
                """,
                bindings: [.text(current.rawValue)]
            )
            for row in rows {
                guard let sessionID = row.text("session_id"),
                      let stored = try session(sessionID)
                else { throw corruptSession("old-epoch cloud session") }
                let closedRecord = SessionRecord(
                    recordSchemaVersion: 2,
                    session: stored.session,
                    lifecycle: .closed
                )
                let changed = try database.executeChanges(
                    """
                    UPDATE prepared_cloud_sessions SET lifecycle = 'closed', record_json = ?1
                    WHERE session_id = ?2 AND host_epoch <> ?3 AND lifecycle <> 'closed'
                    """,
                    bindings: [
                        .text(try encode(closedRecord)), .text(sessionID),
                        .text(current.rawValue),
                    ]
                )
                guard changed == 1 else {
                    throw cloudSessionFailure(
                        "runtime.cloud_session_state_conflict",
                        "old-epoch cloud session changed during recovery"
                    )
                }
                try insertTombstone(CloudSessionTombstone(
                    sessionID: sessionID,
                    closeRevision: 1,
                    disposition: .epochEnded,
                    hostProcessEpoch: stored.session.hostProcessEpoch,
                    closedAt: now
                ))
            }
            _ = try database.executeChanges(
                "DELETE FROM credential_use_leases WHERE host_epoch <> ?1",
                bindings: [.text(current.rawValue)]
            )
            return rows.count
        }
    }

    package func tombstone(_ sessionID: String) throws -> CloudSessionTombstone? {
        let rows = try database.queryRows(
            """
            SELECT close_revision, disposition, record_schema_version, record_json
            FROM cloud_session_tombstones WHERE session_id = ?1
            """,
            bindings: [.text(sessionID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptSession("cloud session tombstone") }
        let record = try decode(TombstoneRecord.self, json)
        guard record.recordSchemaVersion == 2,
              record.tombstone.sessionID == sessionID,
              row.text("close_revision") == String(record.tombstone.closeRevision),
              row.text("disposition") == record.tombstone.disposition.rawValue
        else { throw corruptSession("cloud session tombstone index") }
        return record.tombstone
    }

    package func persistedTextValuesForTesting() throws -> [String] {
        var values: [String] = []
        for table in [
            "prepared_cloud_sessions", "cloud_session_tombstones", "sanitized_llm_snapshots",
        ] {
            for row in try database.query("SELECT * FROM \(table)") {
                values.append(contentsOf: row.values.compactMap { $0 })
            }
        }
        return values
    }

    private func validate(
        session: PreparedCloudSession,
        snapshot: SanitizedCloudSessionSnapshot,
        lease: CredentialUseLease
    ) throws {
        let required = [
            session.sessionID, session.preparationID, session.proposedRunID,
            session.targetID.rawValue, session.bindingID, session.requirementsHash,
            session.providerProfileID, session.credentialRef, session.credentialUseLeaseID,
            session.modelID, session.scopeGrantID, session.generationAuthorizationID,
            session.adapterID, session.adapterVersion, snapshot.snapshotID,
        ]
        let digests = [
            session.bindingHash, session.requirementsHash,
            session.credentialUseLeaseDigest, session.capabilitySnapshotDigest,
            session.resolvedParametersDigest, session.initialDisclosureDigest,
            session.opaqueEgressSubjectDigest, session.egressAttestationDigest,
        ]
        guard required.allSatisfy({ !$0.isEmpty }),
              digests.allSatisfy(isCloudSessionDigest),
              session.targetRevision > 0,
              session.bindingRevision > 0,
              session.providerProfileRevision > 0,
              lease.leaseID == session.credentialUseLeaseID,
              lease.credentialRef == session.credentialRef,
              lease.generation == session.credentialGeneration,
              lease.purpose == .preparation,
              lease.preparationID == session.preparationID,
              lease.hostProcessEpoch == session.hostProcessEpoch,
              lease.lifecycle == .acquired,
              snapshot.sessionID == session.sessionID,
              snapshot.runID == session.proposedRunID,
              snapshot.preparationID == session.preparationID,
              snapshot.hostProcessEpoch == session.hostProcessEpoch,
              snapshot.capabilitySnapshot.subject.llmTargetID == session.targetID,
              snapshot.capabilitySnapshot.subject.llmTargetRevision == session.targetRevision
        else {
            throw cloudSessionFailure(
                "runtime.cloud_prepared_session_invalid",
                "prepared cloud session identity is incomplete or inconsistent"
            )
        }
        switch session.retentionMode {
        case .statelessRequired:
            guard session.retentionApprovalRevision == nil,
                  session.retentionApprovalDigest == nil
            else { throw cloudSessionFailure("runtime.cloud_retention_invalid", "stateless session has retention approval") }
        case .providerStateApproved:
            guard let revision = session.retentionApprovalRevision,
                  revision > 0,
                  let digest = session.retentionApprovalDigest,
                  isCloudSessionDigest(digest)
            else { throw cloudSessionFailure("runtime.cloud_retention_invalid", "stateful session lacks retention approval") }
        }
    }

    private func insertTombstone(_ tombstone: CloudSessionTombstone) throws {
        let record = TombstoneRecord(recordSchemaVersion: 2, tombstone: tombstone)
        try database.execute(
            """
            INSERT INTO cloud_session_tombstones(
              session_id, close_revision, disposition, record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, 2, ?4)
            ON CONFLICT(session_id) DO NOTHING
            """,
            bindings: [
                .text(tombstone.sessionID), .text(String(tombstone.closeRevision)),
                .text(tombstone.disposition.rawValue), .text(try encode(record)),
            ]
        )
        guard let existing = try self.tombstone(tombstone.sessionID), existing == tombstone else {
            throw cloudSessionFailure(
                "runtime.cloud_session_close_conflict",
                "cloud session close tombstone conflicts with an existing close"
            )
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else { throw corruptSession("record encoding") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw corruptSession("record payload") }
    }

    private func corruptSession(_ subject: String) -> LLMFailure {
        cloudSessionFailure(
            "runtime.cloud_persisted_session_corrupt",
            "\(subject) is corrupt"
        )
    }
}

func cloudSessionFailure(_ code: String, _ message: String, retryable: Bool = false) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: retryable)
}

private func isCloudSessionDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.allSatisfy {
        $0.isNumber || ("a"..."f").contains(String($0))
    }
}
