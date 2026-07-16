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
    package static let currentVersion = 2

    package static var versionTwoMigrationStatementCount: Int {
        versionTwoStatements.count
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
        guard version < currentVersion else { return }
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
