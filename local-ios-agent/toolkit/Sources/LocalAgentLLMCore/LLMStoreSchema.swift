import Foundation

package struct LLMStoreSchemaError: Error, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package enum LLMStoreSchema {
    package static let currentVersion = 4

    package static var versionTwoMigrationStatementCount: Int {
        versionTwoStatements.count
    }

    package static let versionThreeMigrationStatementCount = 8
    package static let versionFourMigrationStatementCount = 4

    package static func migrateToCurrent(
        _ database: SQLiteConnection,
        failVersionTwoAfterStatement: Int? = nil,
        failVersionThreeAfterStatement: Int? = nil
    ) throws {
        try ensureBaseSchema(database)
        if try userVersion(database) == 1 {
            try migrateToVersionTwo(
                database,
                failAfterStatement: failVersionTwoAfterStatement
            )
        }
        if try userVersion(database) == 2 {
            try migrateToVersionThree(
                database,
                failAfterStatement: failVersionThreeAfterStatement
            )
        }
        if try userVersion(database) == 3 {
            try migrateToVersionFour(database)
        }
    }

    package static func ensureBaseSchema(_ database: SQLiteConnection) throws {
        let version = try userVersion(database)
        guard version <= currentVersion else {
            throw LLMStoreSchemaError(
                code: "llm_store.future_schema",
                message: "LLM store schema version \(version) is newer than supported version \(currentVersion)"
            )
        }

        try database.transaction {
            for statement in baseStatements {
                try database.execute(statement)
            }
            if version == 0 {
                try database.execute("UPDATE llm_store_meta SET schema_version = 1")
                try database.execute("PRAGMA user_version = 1")
            }
        }
    }

    package static func migrateToVersionTwo(
        _ database: SQLiteConnection,
        failAfterStatement failureIndex: Int? = nil
    ) throws {
        let version = try userVersion(database)
        guard version <= currentVersion else {
            throw LLMStoreSchemaError(
                code: "llm_store.future_schema",
                message: "LLM store schema version \(version) is newer than supported version \(currentVersion)"
            )
        }
        guard version < 2 else { return }
        guard version == 1 else {
            throw LLMStoreSchemaError(
                code: "llm_store.unsupported_migration",
                message: "LLM store must be at schema version 1 before migrating to version 2"
            )
        }

        try database.transaction {
            for (index, statement) in versionTwoStatements.enumerated() {
                try database.execute(statement)
                if failureIndex == index {
                    throw LLMStoreSchemaError(
                        code: "llm_store.injected_migration_failure",
                        message: "injected failure after v2 migration statement \(index)"
                    )
                }
            }
            try database.execute("UPDATE llm_store_meta SET schema_version = 2")
            try database.execute("PRAGMA user_version = 2")
        }
    }

    private static func migrateToVersionThree(
        _ database: SQLiteConnection,
        failAfterStatement failureIndex: Int?
    ) throws {
        let version = try userVersion(database)
        guard version <= currentVersion else {
            throw LLMStoreSchemaError(
                code: "llm_store.future_schema",
                message: "LLM store schema version \(version) is newer than supported version \(currentVersion)"
            )
        }
        guard version < 3 else { return }
        guard version == 2 else {
            throw LLMStoreSchemaError(
                code: "llm_store.unsupported_migration",
                message: "LLM store must be at schema version 2 before migrating to version 3"
            )
        }

        try database.transaction {
            var statementIndex = 0
            func completedStatement() throws {
                defer { statementIndex += 1 }
                guard failureIndex == statementIndex else { return }
                throw LLMStoreSchemaError(
                    code: "llm_store.injected_migration_failure",
                    message: "injected failure after v3 migration statement \(statementIndex)"
                )
            }

            try database.execute(
                """
                CREATE TABLE provider_profile_revisions_v3(
                  profile_id TEXT NOT NULL, revision TEXT NOT NULL, preset_id TEXT NOT NULL,
                  origin TEXT NOT NULL, credential_ref TEXT NOT NULL, retention_mode TEXT NOT NULL,
                  lifecycle TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 3),
                  record_json TEXT NOT NULL, PRIMARY KEY(profile_id, revision)
                )
                """
            )
            try completedStatement()

            for row in try database.queryRows(
                """
                SELECT profile_id, revision, preset_id, origin, credential_ref,
                       retention_mode, lifecycle, record_schema_version, record_json
                FROM provider_profile_revisions ORDER BY profile_id, revision
                """
            ) {
                guard row.integer("record_schema_version") == 2,
                      let profileID = row.text("profile_id"),
                      let revision = row.text("revision"),
                      let presetID = row.text("preset_id"),
                      let origin = row.text("origin"),
                      let credentialRef = row.text("credential_ref"),
                      let retentionMode = row.text("retention_mode"),
                      let lifecycle = row.text("lifecycle"),
                      let recordJSON = row.text("record_json")
                else {
                    throw LLMStoreSchemaError(
                        code: "llm_store.migration_record_invalid",
                        message: "provider profile v2 record is incomplete"
                    )
                }
                let migratedJSON = try migrateProviderProfileEnvelope(
                    recordJSON,
                    expectedLifecycle: lifecycle
                )
                try database.execute(
                    """
                    INSERT INTO provider_profile_revisions_v3(
                      profile_id, revision, preset_id, origin, credential_ref,
                      retention_mode, lifecycle, record_schema_version, record_json
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 3, ?8)
                    """,
                    bindings: [
                        .text(profileID), .text(revision), .text(presetID), .text(origin),
                        .text(credentialRef), .text(retentionMode), .text(lifecycle),
                        .text(migratedJSON),
                    ]
                )
            }
            try completedStatement()

            try database.execute("DROP INDEX provider_profile_revisions_lifecycle_idx")
            try completedStatement()
            try database.execute("DROP TABLE provider_profile_revisions")
            try completedStatement()
            try database.execute(
                "ALTER TABLE provider_profile_revisions_v3 RENAME TO provider_profile_revisions"
            )
            try completedStatement()
            try database.execute(
                "CREATE INDEX provider_profile_revisions_lifecycle_idx ON provider_profile_revisions(lifecycle)"
            )
            try completedStatement()
            try database.execute("UPDATE llm_store_meta SET schema_version = 3")
            try completedStatement()
            try database.execute("PRAGMA user_version = 3")
            try completedStatement()
        }
    }

    private static func migrateToVersionFour(_ database: SQLiteConnection) throws {
        let version = try userVersion(database)
        guard version <= currentVersion else {
            throw LLMStoreSchemaError(
                code: "llm_store.future_schema",
                message: "LLM store schema version \(version) is newer than supported version \(currentVersion)"
            )
        }
        guard version < 4 else { return }
        guard version == 3 else {
            throw LLMStoreSchemaError(
                code: "llm_store.unsupported_migration",
                message: "LLM store must be at schema version 3 before migrating to version 4"
            )
        }
        try database.transaction {
            try database.execute(
                "CREATE TABLE model_rebind_operations(operation_id TEXT PRIMARY KEY, phase TEXT NOT NULL, record_json TEXT NOT NULL)"
            )
            try database.execute(
                "CREATE INDEX model_rebind_operations_phase_idx ON model_rebind_operations(phase)"
            )
            try database.execute("UPDATE llm_store_meta SET schema_version = 4")
            try database.execute("PRAGMA user_version = 4")
        }
    }

    private static func migrateProviderProfileEnvelope(
        _ json: String,
        expectedLifecycle: String
    ) throws -> String {
        guard let root = try JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any],
            (root["record_schema_version"] as? NSNumber)?.intValue == 2,
            let published = root["published"] as? [String: Any],
            let revision = published["revision"] as? [String: Any],
            let origin = published["origin"] as? [String: Any],
            let lifecycle = published["lifecycle"] as? String,
            lifecycle == expectedLifecycle,
            lifecycle == "active" || lifecycle == "archived"
        else {
            throw LLMStoreSchemaError(
                code: "llm_store.migration_record_invalid",
                message: "provider profile v2 envelope is invalid"
            )
        }
        let migrated: [String: Any] = [
            "record_schema_version": 3,
            "revision": revision,
            "origin": origin,
            "lifecycle": ["tag": lifecycle],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: migrated,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    package static func userVersion(_ database: SQLiteConnection) throws -> Int {
        let rows = try database.queryRows("PRAGMA user_version")
        guard let value = rows.first?.integer("user_version") else {
            throw LLMStoreSchemaError(
                code: "llm_store.missing_schema_version",
                message: "SQLite did not return PRAGMA user_version"
            )
        }
        return Int(value)
    }

    private static let baseStatements = [
        "CREATE TABLE IF NOT EXISTS llm_store_meta(schema_version INTEGER NOT NULL)",
        "INSERT INTO llm_store_meta(schema_version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM llm_store_meta)",
        """
        CREATE TABLE IF NOT EXISTS host_bindings(
          operation_token TEXT PRIMARY KEY,
          state TEXT NOT NULL,
          binding_id TEXT NOT NULL,
          binding_revision TEXT NOT NULL,
          binding_hash TEXT NOT NULL,
          record_json TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS host_bindings_state_idx ON host_bindings(state)",
        """
        CREATE TABLE IF NOT EXISTS prepared_sessions(
          preparation_id TEXT PRIMARY KEY,
          state TEXT NOT NULL,
          registration_digest TEXT NOT NULL,
          cleanup_command_id TEXT,
          record_json TEXT NOT NULL
        )
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS prepared_sessions_cleanup_idx ON prepared_sessions(cleanup_command_id) WHERE cleanup_command_id IS NOT NULL",
    ]

    private static let versionTwoStatements = [
        """
        CREATE TABLE provider_profile_revisions(
          profile_id TEXT NOT NULL, revision TEXT NOT NULL, preset_id TEXT NOT NULL,
          origin TEXT NOT NULL, credential_ref TEXT NOT NULL, retention_mode TEXT NOT NULL,
          lifecycle TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL, PRIMARY KEY(profile_id, revision)
        )
        """,
        """
        CREATE TABLE provider_profile_state(
          profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL,
          retention_approval_revision TEXT, retention_approval_digest TEXT, catalog_revision TEXT,
          state_revision TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL, PRIMARY KEY(profile_id, profile_revision)
        )
        """,
        """
        CREATE TABLE llm_target_revisions(
          target_id TEXT NOT NULL, revision TEXT NOT NULL, kind TEXT NOT NULL, model_id TEXT NOT NULL,
          profile_id TEXT, profile_revision TEXT,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL,
          PRIMARY KEY(target_id, revision)
        )
        """,
        """
        CREATE TABLE provider_origin_approvals(
          profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL, approval_revision TEXT NOT NULL,
          origin TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL, PRIMARY KEY(profile_id, profile_revision, approval_revision)
        )
        """,
        """
        CREATE TABLE provider_retention_approvals(
          profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL, approval_revision TEXT NOT NULL,
          retention_mode TEXT NOT NULL, behavior TEXT NOT NULL, window_class TEXT NOT NULL,
          decision TEXT NOT NULL, approval_digest TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL,
          PRIMARY KEY(profile_id, profile_revision, approval_revision)
        )
        """,
        """
        CREATE TABLE credential_creation_operations(
          operation_id TEXT PRIMARY KEY, credential_ref TEXT NOT NULL, generation TEXT NOT NULL,
          phase TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE credential_slots(
          credential_ref TEXT PRIMARY KEY, current_generation TEXT NOT NULL, lifecycle TEXT NOT NULL,
          operation_id TEXT, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE credential_use_leases(
          lease_id TEXT PRIMARY KEY, credential_ref TEXT NOT NULL, generation TEXT NOT NULL,
          purpose TEXT NOT NULL, preparation_id TEXT, host_epoch TEXT NOT NULL, lifecycle TEXT NOT NULL,
          revision TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE credential_operation_tombstones(
          operation_id TEXT PRIMARY KEY, credential_ref TEXT NOT NULL, operation_kind TEXT NOT NULL,
          phase TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE credential_key_tombstones(
          tombstone_id TEXT PRIMARY KEY, credential_ref TEXT NOT NULL, generation TEXT NOT NULL,
          phase TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE egress_scope_grants(
          grant_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, profile_id TEXT NOT NULL,
          profile_revision TEXT NOT NULL, credential_generation TEXT NOT NULL,
          retention_mode TEXT NOT NULL, retention_approval_revision TEXT,
          retention_approval_digest TEXT, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE egress_generation_authorizations(
          authorization_id TEXT PRIMARY KEY, generation_turn_id TEXT NOT NULL, grant_id TEXT NOT NULL,
          credential_generation TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE egress_audit_records(
          audit_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, generation_turn_id TEXT NOT NULL,
          previous_chain_digest TEXT, chain_digest TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE cloud_catalog_state(
          catalog_id TEXT PRIMARY KEY, catalog_revision TEXT NOT NULL, key_id TEXT NOT NULL,
          payload_digest TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE cloud_capability_observations(
          observation_digest TEXT PRIMARY KEY, profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL,
          model_id TEXT NOT NULL, credential_generation TEXT NOT NULL, expires_at TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE provider_validation_records(
          validation_id TEXT PRIMARY KEY, profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL,
          model_id TEXT NOT NULL, credential_generation TEXT NOT NULL, expires_at TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE prepared_cloud_sessions(
          session_id TEXT PRIMARY KEY, preparation_id TEXT NOT NULL, proposed_run_id TEXT NOT NULL,
          host_epoch TEXT NOT NULL, lifecycle TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE cloud_session_tombstones(
          session_id TEXT PRIMARY KEY, close_revision TEXT NOT NULL, disposition TEXT NOT NULL,
          record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2), record_json TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE sanitized_llm_snapshots(
          snapshot_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, preparation_id TEXT NOT NULL,
          host_epoch TEXT NOT NULL, record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 2),
          record_json TEXT NOT NULL
        )
        """,
        "CREATE INDEX provider_profile_revisions_lifecycle_idx ON provider_profile_revisions(lifecycle)",
        "CREATE INDEX provider_profile_state_revision_idx ON provider_profile_state(profile_id, profile_revision, state_revision)",
        "CREATE INDEX llm_target_profile_idx ON llm_target_revisions(profile_id, profile_revision)",
        "CREATE INDEX provider_origin_approvals_origin_idx ON provider_origin_approvals(origin)",
        "CREATE INDEX provider_retention_approvals_profile_idx ON provider_retention_approvals(profile_id, profile_revision)",
        "CREATE INDEX credential_creation_operations_ref_idx ON credential_creation_operations(credential_ref)",
        "CREATE INDEX credential_slots_lifecycle_idx ON credential_slots(lifecycle)",
        "CREATE INDEX credential_use_leases_slot_idx ON credential_use_leases(credential_ref, generation, lifecycle)",
        "CREATE INDEX credential_use_leases_epoch_idx ON credential_use_leases(host_epoch, lifecycle)",
        "CREATE INDEX credential_operation_tombstones_ref_idx ON credential_operation_tombstones(credential_ref)",
        "CREATE INDEX credential_key_tombstones_ref_idx ON credential_key_tombstones(credential_ref, generation)",
        "CREATE INDEX egress_scope_grants_subject_idx ON egress_scope_grants(profile_id, profile_revision, credential_generation)",
        "CREATE INDEX egress_generation_authorizations_turn_idx ON egress_generation_authorizations(generation_turn_id)",
        "CREATE INDEX egress_audit_records_run_idx ON egress_audit_records(run_id, generation_turn_id)",
        "CREATE INDEX cloud_catalog_state_revision_idx ON cloud_catalog_state(catalog_revision)",
        "CREATE INDEX cloud_capability_observations_subject_idx ON cloud_capability_observations(profile_id, profile_revision, model_id, credential_generation)",
        "CREATE INDEX provider_validation_records_subject_idx ON provider_validation_records(profile_id, profile_revision, model_id, credential_generation)",
        "CREATE INDEX prepared_cloud_sessions_preparation_idx ON prepared_cloud_sessions(preparation_id)",
        "CREATE INDEX prepared_cloud_sessions_epoch_idx ON prepared_cloud_sessions(host_epoch, lifecycle)",
        "CREATE INDEX cloud_session_tombstones_revision_idx ON cloud_session_tombstones(close_revision)",
        "CREATE INDEX sanitized_llm_snapshots_run_idx ON sanitized_llm_snapshots(run_id, preparation_id)",
    ]
}
