import Foundation
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("LLMStore schema v3")
struct LLMStoreSchemaV3Tests {
    @Test
    func emptyV1MigratesToTheCompleteCurrentSchema() async throws {
        let directory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        _ = try LLMStore(fileURL: url)

        let store = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )

        #expect(await store.schemaVersionForTesting() == 3)
        #expect(Set(await store.tableNamesForTesting()) == expectedVersionTwoTables)
        #expect(Set(await store.indexNamesForTesting()) == expectedVersionTwoIndexes)
    }

    @Test
    func populatedV1SurvivesMigrationAndReopen() async throws {
        let directory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let base = try LLMStore(fileURL: url)
        let configuration = AgentHostConfiguration(
            bindingID: "binding-v1",
            revision: 1,
            agentProfileID: "agent-v1",
            agentProfileRevision: 1,
            llmSlotID: "assistant",
            requirementsHash: "requirements-v1",
            llmTargetID: .init(rawValue: "target-v1"),
            llmTargetRevision: 1,
            parameterOverrides: .init()
        )
        let request = HostBindingStageRequest(
            operationToken: "ephemeral-token",
            tokenDigest: "persisted-token-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        )
        _ = try await AgentHostBindingSaga(store: base).stageHostBinding(request)

        _ = try ProviderProfileStore(fileURL: url, originValidator: FixtureOriginValidator())
        let reopened = try LLMStore(fileURL: url)

        #expect(await reopened.schemaVersionForTesting() == 3)
        #expect(await reopened.bindingState(token: request.tokenDigest) == .staged)
    }

    @Test
    func everyInjectedMigrationBoundaryRollsBackToIntactV1() async throws {
        for failureIndex in 0..<LLMStoreSchema.versionTwoMigrationStatementCount {
            let directory = temporarySchemaDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("llm-state.sqlite")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let versionOne = try SQLiteConnection(path: url.path)
            try LLMStoreSchema.ensureBaseSchema(versionOne)

            #expect(throws: (any Error).self) {
                _ = try ProviderProfileStore(
                    fileURL: url,
                    originValidator: FixtureOriginValidator(),
                    failMigrationAfterStatement: failureIndex
                )
            }

            let connection = try SQLiteConnection(path: url.path)
            #expect(try userVersion(connection) == 1)
            #expect(Set(try tableNames(connection)) == expectedVersionOneTables)
        }
    }

    @Test
    func populatedVersionTwoMigratesToTaggedVersionThreeAndReopens() async throws {
        let directory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let expected = try createVersionTwoProfileFixture(at: url)
        let connection = try SQLiteConnection(path: url.path)

        try LLMStoreSchema.migrateToCurrent(connection)

        #expect(try userVersion(connection) == 3)
        #expect(try connection.queryRows(
            "SELECT record_schema_version FROM provider_profile_revisions ORDER BY revision"
        ).map { $0.integer("record_schema_version") } == [3, 3])
        let reopened = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        #expect(await reopened.profile(profileID: "migrated-profile", revision: 1) == expected[0])
        #expect(await reopened.profile(profileID: "migrated-profile", revision: 2) == expected[1])
    }

    @Test
    func everyVersionThreeMigrationBoundaryRollsBackToIntactVersionTwo() throws {
        for failureIndex in 0..<LLMStoreSchema.versionThreeMigrationStatementCount {
            let directory = temporarySchemaDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("llm-state.sqlite")
            _ = try createVersionTwoProfileFixture(at: url)
            let connection = try SQLiteConnection(path: url.path)
            let before = try rawSchemaProjection(connection)

            #expect(throws: LLMStoreSchemaError.self) {
                try LLMStoreSchema.migrateToCurrent(
                    connection,
                    failVersionThreeAfterStatement: failureIndex
                )
            }

            #expect(try userVersion(connection) == 2)
            #expect(try rawSchemaProjection(connection) == before)
        }
    }

    @Test
    func futureVersionAndUnknownPersistedShapesFailClosed() throws {
        let futureDirectory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: futureDirectory) }
        try FileManager.default.createDirectory(
            at: futureDirectory,
            withIntermediateDirectories: true
        )
        let futureURL = futureDirectory.appendingPathComponent("llm-state.sqlite")
        let future = try SQLiteConnection(path: futureURL.path)
        try LLMStoreSchema.ensureBaseSchema(future)
        try future.execute("PRAGMA user_version = 4")
        #expect(throws: ProviderProfileFailure.self) {
            _ = try ProviderProfileStore(
                fileURL: futureURL,
                originValidator: FixtureOriginValidator()
            )
        }

        let unknownDirectory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: unknownDirectory) }
        let unknownURL = unknownDirectory.appendingPathComponent("llm-state.sqlite")
        let valid = try ProviderProfileStore(
            fileURL: unknownURL,
            originValidator: FixtureOriginValidator()
        )
        let connection = try SQLiteConnection(path: unknownURL.path)
        try connection.execute(
            "INSERT INTO provider_profile_revisions(profile_id, revision, preset_id, origin, credential_ref, retention_mode, lifecycle, record_schema_version, record_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            bindings: [
                .text("unknown-record"), .text("1"), .text("openai"),
                .text("https://api.openai.com:443"), .text("credential"),
                .text("stateless_required"), .text("active"), .integer(3),
                .text(#"{"record_schema_version":99}"#),
            ]
        )
        _ = valid
        #expect(throws: ProviderProfileFailure.self) {
            _ = try ProviderProfileStore(
                fileURL: unknownURL,
                originValidator: FixtureOriginValidator()
            )
        }

        let enumDirectory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: enumDirectory) }
        let enumURL = enumDirectory.appendingPathComponent("llm-state.sqlite")
        _ = try ProviderProfileStore(
            fileURL: enumURL,
            originValidator: FixtureOriginValidator()
        )
        let enumConnection = try SQLiteConnection(path: enumURL.path)
        try enumConnection.execute(
            "INSERT INTO provider_profile_state(profile_id, profile_revision, retention_approval_revision, retention_approval_digest, catalog_revision, state_revision, record_schema_version, record_json) VALUES (?1, ?2, NULL, NULL, NULL, ?3, 2, ?4)",
            bindings: [
                .text("future-enum"), .text("1"), .text("1"),
                .text(#"{"record_schema_version":2,"state":{"profileID":"future-enum","profileRevision":1,"stateRevision":1,"validationState":{"tag":"future_validation_state"}}}"#),
            ]
        )
        #expect(throws: ProviderProfileFailure.self) {
            _ = try ProviderProfileStore(
                fileURL: enumURL,
                originValidator: FixtureOriginValidator()
            )
        }
    }

    @Test
    func finalSchemaAcceptsOneVersionedRowForEveryLaterTaskTable() throws {
        let directory = temporarySchemaDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        _ = try ProviderProfileStore(fileURL: url, originValidator: FixtureOriginValidator())
        let connection = try SQLiteConnection(path: url.path)

        for fixture in laterTaskRowFixtures {
            try connection.execute(fixture.sql, bindings: fixture.bindings)
        }

        #expect(try userVersion(connection) == 3)
        #expect(Set(try tableNames(connection)) == expectedVersionTwoTables)
    }
}

private let expectedVersionOneTables: Set<String> = [
    "host_bindings", "llm_store_meta", "prepared_sessions",
]

private let expectedVersionTwoTables = expectedVersionOneTables.union([
    "provider_profile_revisions", "provider_profile_state", "llm_target_revisions",
    "provider_origin_approvals", "provider_retention_approvals",
    "credential_creation_operations", "credential_slots", "credential_use_leases",
    "credential_operation_tombstones", "credential_key_tombstones",
    "egress_scope_grants", "egress_generation_authorizations", "egress_audit_records",
    "cloud_catalog_state", "cloud_capability_observations", "provider_validation_records",
    "prepared_cloud_sessions", "cloud_session_tombstones", "sanitized_llm_snapshots",
])

private let expectedVersionTwoIndexes: Set<String> = [
    "host_bindings_state_idx", "prepared_sessions_cleanup_idx",
    "provider_profile_revisions_lifecycle_idx", "provider_profile_state_revision_idx",
    "llm_target_profile_idx", "provider_origin_approvals_origin_idx",
    "provider_retention_approvals_profile_idx", "credential_creation_operations_ref_idx",
    "credential_slots_lifecycle_idx", "credential_use_leases_slot_idx",
    "credential_use_leases_epoch_idx", "credential_operation_tombstones_ref_idx",
    "credential_key_tombstones_ref_idx", "egress_scope_grants_subject_idx",
    "egress_generation_authorizations_turn_idx", "egress_audit_records_run_idx",
    "cloud_catalog_state_revision_idx", "cloud_capability_observations_subject_idx",
    "provider_validation_records_subject_idx", "prepared_cloud_sessions_preparation_idx",
    "prepared_cloud_sessions_epoch_idx", "cloud_session_tombstones_revision_idx",
    "sanitized_llm_snapshots_run_idx",
]

private struct LaterTaskRowFixture {
    let sql: String
    let bindings: [SQLiteValue]
}

private let versionedJSON = #"{"record_schema_version":2}"#

private let laterTaskRowFixtures: [LaterTaskRowFixture] = [
    .init(sql: "INSERT INTO provider_origin_approvals VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("profile"),.text("1"),.text("1"),.text("https://api.example.com:443"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO provider_retention_approvals VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)", bindings: [.text("profile"),.text("1"),.text("1"),.text("provider_state_approved"),.text("response_continuation"),.text("provider_defined"),.text("approved"),.text(String(repeating:"b",count:64)),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO credential_creation_operations VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("create-1"),.text("cred"),.text("1"),.text("intent"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO credential_slots VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("cred"),.text("1"),.text("active"),.null,.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO credential_use_leases VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)", bindings: [.text("lease"),.text("cred"),.text("1"),.text("validation"),.null,.text("epoch"),.text("acquired"),.text("1"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO credential_operation_tombstones VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("op"),.text("cred"),.text("rotation"),.text("complete"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO credential_key_tombstones VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("key"),.text("cred"),.text("1"),.text("complete"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO egress_scope_grants VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)", bindings: [.text("grant"),.text("run"),.text("profile"),.text("1"),.text("1"),.text("stateless_required"),.null,.null,.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO egress_generation_authorizations VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("authorization"),.text("turn"),.text("grant"),.text("1"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO egress_audit_records VALUES (?1,?2,?3,?4,?5,?6,?7)", bindings: [.text("audit"),.text("run"),.text("turn"),.null,.text(String(repeating:"c",count:64)),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO cloud_catalog_state VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("catalog"),.text("1"),.text("key"),.text(String(repeating:"a",count:64)),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO cloud_capability_observations VALUES (?1,?2,?3,?4,?5,?6,?7,?8)", bindings: [.text("obs"),.text("profile"),.text("1"),.text("model"),.text("1"),.text("2027-01-01T00:00:00.000Z"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO provider_validation_records VALUES (?1,?2,?3,?4,?5,?6,?7,?8)", bindings: [.text("validation"),.text("profile"),.text("1"),.text("model"),.text("1"),.text("2027-01-01T00:00:00.000Z"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO prepared_cloud_sessions VALUES (?1,?2,?3,?4,?5,?6,?7)", bindings: [.text("session"),.text("prep"),.text("run"),.text("epoch"),.text("prepared"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO cloud_session_tombstones VALUES (?1,?2,?3,?4,?5)", bindings: [.text("closed"),.text("1"),.text("closed"),.integer(2),.text(versionedJSON)]),
    .init(sql: "INSERT INTO sanitized_llm_snapshots VALUES (?1,?2,?3,?4,?5,?6)", bindings: [.text("snapshot"),.text("run"),.text("prep"),.text("epoch"),.integer(2),.text(versionedJSON)]),
]

private func temporarySchemaDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "llm-schema-v3-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func createVersionTwoProfileFixture(
    at url: URL
) throws -> [PublishedProviderProfileRevision] {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let connection = try SQLiteConnection(path: url.path)
    try LLMStoreSchema.ensureBaseSchema(connection)
    try LLMStoreSchema.migrateToVersionTwo(connection)
    let revision1 = ProviderProfileRevision(
        profileID: "migrated-profile",
        revision: 1,
        presetID: .openAI,
        displayName: "Migrated active",
        baseURL: URL(string: "https://api.example.com/v1")!,
        credentialRef: "credential-active"
    )
    let revision2 = ProviderProfileRevision(
        profileID: "migrated-profile",
        revision: 2,
        presetID: .anthropic,
        displayName: "Migrated archived",
        baseURL: URL(string: "https://api.anthropic.com")!,
        credentialRef: "credential-archived",
        retentionMode: .providerStateApproved
    )
    let published = [
        PublishedProviderProfileRevision(
            revision: revision1,
            origin: EgressOrigin(scheme: "https", host: "api.example.com", port: 443),
            lifecycle: .active
        ),
        PublishedProviderProfileRevision(
            revision: revision2,
            origin: EgressOrigin(scheme: "https", host: "api.anthropic.com", port: 443),
            lifecycle: .archived
        ),
    ]
    for value in published {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(
            LegacyPersistedProfileRevisionV2(published: value)
        ), as: UTF8.self)
        try connection.execute(
            """
            INSERT INTO provider_profile_revisions(
              profile_id, revision, preset_id, origin, credential_ref, retention_mode,
              lifecycle, record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 2, ?8)
            """,
            bindings: [
                .text(value.revision.profileID),
                .text(String(value.revision.revision)),
                .text(value.revision.presetID.rawValue),
                .text(value.origin.serialized),
                .text(value.revision.credentialRef),
                .text(value.revision.retentionMode.rawValue),
                .text(value.lifecycle.rawValue),
                .text(json),
            ]
        )
    }
    return published
}

private struct LegacyPersistedProfileRevisionV2: Encodable {
    let recordSchemaVersion = 2
    let published: PublishedProviderProfileRevision

    enum CodingKeys: String, CodingKey {
        case recordSchemaVersion = "record_schema_version"
        case published
    }
}

private func rawSchemaProjection(
    _ connection: SQLiteConnection
) throws -> [[String: String?]] {
    try connection.query(
        """
        SELECT type, name, sql FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_%'
        UNION ALL
        SELECT 'profile-row', profile_id || ':' || revision, record_json
        FROM provider_profile_revisions
        ORDER BY type, name
        """
    )
}

private func userVersion(_ connection: SQLiteConnection) throws -> Int {
    Int(try #require(connection.queryRows("PRAGMA user_version").first?.integer("user_version")))
}

private func tableNames(_ connection: SQLiteConnection) throws -> [String] {
    try connection.queryRows(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).compactMap { $0.text("name") }
}
