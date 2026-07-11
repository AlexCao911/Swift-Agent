use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension, Row, TransactionBehavior};

use crate::llm_contracts::{
    GlobalRunLease, GlobalRunLeaseError, GlobalRunLeaseState, HostBindingCommit,
    HostBindingCrossLink, HostBindingError, HostBindingKind, HostBindingOperation,
    HostBindingOperationState, HostBindingStagingReceipt, HostBindingTuple, LLMBindingSchema,
    PackageBindingPreparation, PreparationError, ProfilePublishPreparation, RunPreparationRecord,
    RunPreparationState,
};

use super::in_memory::{busy, stale};
use super::in_memory::{conflict, not_found, saga_token_digest, validate_commit};
use super::{AgentOSStateRepository, GlobalRunLeaseRepository, RunPreparationRepository};

pub struct SqliteAgentOSStateStore {
    conn: Connection,
    bearer_tokens: HashMap<String, String>,
}

impl SqliteAgentOSStateStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, HostBindingError> {
        let conn = Connection::open(path).map_err(sqlite_error)?;
        Self::from_connection(conn)
    }

    pub fn open_in_memory() -> Result<Self, HostBindingError> {
        let conn = Connection::open_in_memory().map_err(sqlite_error)?;
        Self::from_connection(conn)
    }

    fn from_connection(conn: Connection) -> Result<Self, HostBindingError> {
        conn.busy_timeout(Duration::from_secs(5))
            .map_err(sqlite_error)?;
        conn.execute_batch(
            "pragma foreign_keys = on;
             create table if not exists agent_os_schema_meta (
               singleton_id integer primary key check (singleton_id = 1),
               schema_version integer not null,
               last_lease_generation integer not null default 0
             );
             insert or ignore into agent_os_schema_meta(singleton_id, schema_version, last_lease_generation) values (1, 1, 0);

             create table if not exists global_run_lease (
               singleton_id integer primary key check (singleton_id = 1),
               lease_generation integer not null,
               owner_run_id text,
               preparation_id text,
               binding_schema text not null,
               host_process_epoch text not null,
               state text not null,
               preparation_expiration text
             );

             create table if not exists host_binding_operations (
               operation_token text primary key,
               token_digest text not null,
               operation_kind text not null,
               idempotency_key text not null,
               subject_id text not null,
               agent_profile_id text not null,
               agent_profile_revision text not null,
               llm_slot_id text not null,
               requirements_hash text not null,
               state text not null,
               unique(operation_kind, idempotency_key)
             );

             create table if not exists host_binding_cross_links (
               operation_token text primary key references host_binding_operations(operation_token),
               token_digest text not null,
               operation_kind text not null,
               llm_slot_id text not null,
               requirements_hash text not null,
               binding_id text not null,
               binding_revision text not null,
               binding_hash text not null,
               staging_receipt_digest text not null,
               state text not null
             );

             create table if not exists run_preparations (
               preparation_id text primary key,
               idempotency_key text not null unique,
               proposed_run_id text not null unique,
               token_digest text not null,
               binding_digest text not null,
               source_revisions_digest text not null,
               host_process_epoch text not null,
               lease_generation text not null,
               state text not null,
               record_json text not null
             );",
        )
        .map_err(sqlite_error)?;
        ensure_lease_generation_counter(&conn)?;
        ensure_preparation_columns(&conn)?;
        Ok(Self {
            conn,
            bearer_tokens: HashMap::new(),
        })
    }

    pub fn table_names(&self) -> Result<Vec<String>, HostBindingError> {
        let mut statement = self
            .conn
            .prepare("select name from sqlite_master where type = 'table' order by name")
            .map_err(sqlite_error)?;
        let names = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)?;
        Ok(names)
    }

    #[allow(clippy::too_many_arguments)]
    fn prepare_operation(
        &mut self,
        kind: HostBindingKind,
        idempotency_key: &str,
        subject_id: &str,
        profile_id: &str,
        profile_revision: u64,
        slot_id: &str,
        requirements_hash: &str,
        token: String,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let token_digest = saga_token_digest(&token)?;
        let tx = self.conn.transaction().map_err(sqlite_error)?;
        if let Some(existing) = load_operation_by_key(&tx, kind, idempotency_key)? {
            tx.commit().map_err(sqlite_error)?;
            if existing.kind() == kind
                && existing.subject_id() == subject_id
                && existing.agent_profile_id() == profile_id
                && existing.agent_profile_revision() == profile_revision
                && existing.llm_slot_id() == slot_id
                && existing.requirements_hash() == requirements_hash
            {
                let raw = self
                    .bearer_tokens
                    .get(existing.token_digest())
                    .cloned()
                    .ok_or_else(|| {
                        HostBindingError::new(
                            "host_binding.token_unavailable",
                            "host-binding bearer is unavailable after restart; resume rotation is required",
                        )
                    })?;
                return Ok(existing.with_token(raw));
            }
            return Err(conflict());
        }
        tx.execute(
            "insert into host_binding_operations (
               operation_token, token_digest, operation_kind, idempotency_key, subject_id,
               agent_profile_id, agent_profile_revision, llm_slot_id, requirements_hash, state
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'pending')",
            params![
                token_digest,
                token_digest,
                kind.as_str(),
                idempotency_key,
                subject_id,
                profile_id,
                profile_revision.to_string(),
                slot_id,
                requirements_hash
            ],
        )
        .map_err(|error| {
            if error.sqlite_error_code() == Some(rusqlite::ErrorCode::ConstraintViolation) {
                conflict()
            } else {
                sqlite_error(error)
            }
        })?;
        let operation = load_operation(&tx, &token_digest)?
            .ok_or_else(not_found)?
            .with_token(token.clone());
        tx.commit().map_err(sqlite_error)?;
        self.bearer_tokens.insert(token_digest, token);
        Ok(operation)
    }

    fn commit_operation(
        &mut self,
        expected_kind: HostBindingKind,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let tx = self.conn.transaction().map_err(sqlite_error)?;
        let presented_digest = saga_token_digest(request.token())?;
        let operation = load_operation(&tx, &presented_digest)?
            .ok_or_else(not_found)?
            .with_token(request.token().to_string());
        validate_commit(expected_kind, &operation, &request)?;
        let expected = HostBindingCrossLink::new(&operation, &request);
        if let Some(existing) = load_cross_link(&tx, &presented_digest)? {
            tx.commit().map_err(sqlite_error)?;
            return if existing == expected {
                Ok(existing)
            } else {
                Err(conflict())
            };
        }
        let binding = request.binding();
        tx.execute(
            "insert into host_binding_cross_links (
               operation_token, token_digest, operation_kind, llm_slot_id, requirements_hash,
               binding_id, binding_revision, binding_hash, staging_receipt_digest, state
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'host_unbound')",
            params![
                operation.token_digest(),
                operation.token_digest(),
                operation.kind().as_str(),
                operation.llm_slot_id(),
                operation.requirements_hash(),
                binding.binding_id(),
                binding.binding_revision().to_string(),
                binding.binding_hash(),
                request.receipt().receipt_digest()
            ],
        )
        .map_err(sqlite_error)?;
        let changed = tx
            .execute(
                "update host_binding_operations set state = 'host_unbound'
             where operation_token = ?1 and state = 'pending'",
                params![operation.token_digest()],
            )
            .map_err(sqlite_error)?;
        if changed != 1 {
            return Err(HostBindingError::new(
                "host_binding.stale_state",
                "host-binding operation was not pending",
            ));
        }
        tx.commit().map_err(sqlite_error)?;
        Ok(expected)
    }
}

fn ensure_lease_generation_counter(conn: &Connection) -> Result<(), HostBindingError> {
    let mut statement = conn
        .prepare("pragma table_info(agent_os_schema_meta)")
        .map_err(sqlite_error)?;
    let mut rows = statement.query([]).map_err(sqlite_error)?;
    let mut found = false;
    while let Some(row) = rows.next().map_err(sqlite_error)? {
        if row.get::<_, String>(1).map_err(sqlite_error)? == "last_lease_generation" {
            found = true;
            break;
        }
    }
    drop(rows);
    drop(statement);
    if !found {
        conn.execute(
            "alter table agent_os_schema_meta add column last_lease_generation integer not null default 0",
            [],
        )
        .map_err(sqlite_error)?;
    }
    Ok(())
}

fn ensure_preparation_columns(conn: &Connection) -> Result<(), HostBindingError> {
    for (name, definition) in [
        ("proposed_run_id", "text not null default ''"),
        ("host_process_epoch", "text not null default ''"),
        ("lease_generation", "text not null default '0'"),
        ("record_json", "text not null default '{}'"),
    ] {
        let mut statement = conn
            .prepare("pragma table_info(run_preparations)")
            .map_err(sqlite_error)?;
        let names = statement
            .query_map([], |row| row.get::<_, String>(1))
            .map_err(sqlite_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(sqlite_error)?;
        drop(statement);
        if !names.iter().any(|existing| existing == name) {
            conn.execute(
                &format!("alter table run_preparations add column {name} {definition}"),
                [],
            )
            .map_err(sqlite_error)?;
        }
    }
    Ok(())
}

impl AgentOSStateRepository for SqliteAgentOSStateStore {
    fn prepare_profile_publish(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let token = crate::llm_contracts::BearerTokenIssuer::system()
            .issue("saga-token:v1")
            .map_err(|error| HostBindingError::new("host_binding.token_failed", error.to_string()))?
            .raw()
            .to_string();
        self.prepare_operation(
            HostBindingKind::ProfilePublish,
            request.idempotency_key(),
            request.agent_profile_id(),
            request.agent_profile_id(),
            request.agent_profile_revision(),
            request.llm_slot_id(),
            request.requirements_hash(),
            token,
        )
    }
    fn commit_profile_publish(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.commit_operation(HostBindingKind::ProfilePublish, request)
    }
    fn begin_package_binding(
        &mut self,
        request: PackageBindingPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let token = crate::llm_contracts::BearerTokenIssuer::system()
            .issue("saga-token:v1")
            .map_err(|error| HostBindingError::new("host_binding.token_failed", error.to_string()))?
            .raw()
            .to_string();
        self.prepare_operation(
            HostBindingKind::PackageBinding,
            request.idempotency_key(),
            request.installation_id(),
            request.agent_profile_id(),
            request.agent_profile_revision(),
            request.llm_slot_id(),
            request.requirements_hash(),
            token,
        )
    }
    fn attach_host_binding(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.commit_operation(HostBindingKind::PackageBinding, request)
    }
    fn cross_link(
        &self,
        operation_token: &str,
    ) -> Result<Option<HostBindingCrossLink>, HostBindingError> {
        let digest = saga_token_digest(operation_token)?;
        load_cross_link(&self.conn, &digest)
    }
}

impl RunPreparationRepository for SqliteAgentOSStateStore {
    fn create_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        if let Some(existing) = load_preparation(&self.conn, record.preview().preparation_id())? {
            return if existing == record {
                Ok(existing)
            } else {
                Err(preparation_conflict())
            };
        }
        let json = serde_json::to_string(&record).map_err(preparation_serde_error)?;
        self.conn
            .execute(
                "insert into run_preparations (
               preparation_id, idempotency_key, proposed_run_id, token_digest, binding_digest,
               source_revisions_digest, host_process_epoch, lease_generation, state, record_json
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    record.preview().preparation_id(),
                    record.idempotency_key(),
                    record.preview().proposed_run_id(),
                    record.preview().token_digest(),
                    record.preview().binding_digest(),
                    record.preview().binding().source_revisions_digest(),
                    record.preview().host_process_epoch(),
                    record.preview().lease_generation().to_string(),
                    record.state().as_str(),
                    json
                ],
            )
            .map_err(|error| {
                if error.sqlite_error_code() == Some(rusqlite::ErrorCode::ConstraintViolation) {
                    preparation_conflict()
                } else {
                    preparation_sqlite_error(error)
                }
            })?;
        Ok(record)
    }

    fn save_run_preparation(
        &mut self,
        expected_state: RunPreparationState,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let json = serde_json::to_string(&record).map_err(preparation_serde_error)?;
        let changed = self
            .conn
            .execute(
                "update run_preparations set token_digest = ?1, state = ?2, record_json = ?3
             where preparation_id = ?4 and state = ?5",
                params![
                    record.preview().token_digest(),
                    record.state().as_str(),
                    json,
                    record.preview().preparation_id(),
                    expected_state.as_str()
                ],
            )
            .map_err(preparation_sqlite_error)?;
        if changed != 1 {
            return Err(preparation_stale());
        }
        Ok(record)
    }

    fn abort_run_preparation(
        &mut self,
        record: RunPreparationRecord,
        has_registered_session: bool,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(preparation_sqlite_error)?;
        let preview = record.preview();
        let changed = tx
            .execute(
                "update global_run_lease set state = 'releasing'
             where singleton_id = 1 and lease_generation = ?1 and preparation_id = ?2
               and host_process_epoch = ?3 and state = 'preparing'",
                params![
                    preview.lease_generation().to_string(),
                    preview.preparation_id(),
                    preview.host_process_epoch()
                ],
            )
            .map_err(preparation_sqlite_error)?;
        if changed != 1 {
            return Err(preparation_stale());
        }
        let json = serde_json::to_string(&record).map_err(preparation_serde_error)?;
        let updated = tx
            .execute(
                "update run_preparations set token_digest = ?1, state = ?2, record_json = ?3
             where preparation_id = ?4 and state in ('pending', 'registered')",
                params![
                    record.preview().token_digest(),
                    record.state().as_str(),
                    json,
                    preview.preparation_id()
                ],
            )
            .map_err(preparation_sqlite_error)?;
        if updated != 1 {
            return Err(preparation_stale());
        }
        if !has_registered_session {
            let released = tx
                .execute(
                    "delete from global_run_lease where singleton_id = 1 and lease_generation = ?1
                 and host_process_epoch = ?2 and state = 'releasing'",
                    params![
                        preview.lease_generation().to_string(),
                        preview.host_process_epoch()
                    ],
                )
                .map_err(preparation_sqlite_error)?;
            if released != 1 {
                return Err(preparation_stale());
            }
        }
        tx.commit().map_err(preparation_sqlite_error)?;
        Ok(record)
    }

    fn close_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(preparation_sqlite_error)?;
        let preview = record.preview();
        let json = serde_json::to_string(&record).map_err(preparation_serde_error)?;
        let updated = tx
            .execute(
                "update run_preparations set state = 'closed', record_json = ?1
             where preparation_id = ?2 and state = 'aborting'",
                params![json, preview.preparation_id()],
            )
            .map_err(preparation_sqlite_error)?;
        if updated != 1 {
            return Err(preparation_stale());
        }
        let released = tx
            .execute(
                "delete from global_run_lease where singleton_id = 1 and lease_generation = ?1
             and host_process_epoch = ?2 and state = 'releasing'",
                params![
                    preview.lease_generation().to_string(),
                    preview.host_process_epoch()
                ],
            )
            .map_err(preparation_sqlite_error)?;
        if released != 1 {
            return Err(preparation_stale());
        }
        tx.commit().map_err(preparation_sqlite_error)?;
        Ok(record)
    }

    fn run_preparation(
        &self,
        preparation_id: &str,
    ) -> Result<Option<RunPreparationRecord>, PreparationError> {
        load_preparation(&self.conn, preparation_id)
    }

    fn active_run_preparation(&self) -> Result<Option<RunPreparationRecord>, PreparationError> {
        self.conn
            .query_row(
                "select p.record_json from run_preparations p join global_run_lease l
             on l.preparation_id = p.preparation_id where l.singleton_id = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(preparation_sqlite_error)?
            .map(|json| serde_json::from_str(&json).map_err(preparation_serde_error))
            .transpose()
    }

    fn list_run_preparations(&self) -> Result<Vec<RunPreparationRecord>, PreparationError> {
        let mut statement = self
            .conn
            .prepare("select record_json from run_preparations order by preparation_id")
            .map_err(preparation_sqlite_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(preparation_sqlite_error)?;
        let mut records = Vec::new();
        for row in rows {
            records.push(
                serde_json::from_str(&row.map_err(preparation_sqlite_error)?)
                    .map_err(preparation_serde_error)?,
            );
        }
        Ok(records)
    }
}

fn load_preparation(
    conn: &Connection,
    preparation_id: &str,
) -> Result<Option<RunPreparationRecord>, PreparationError> {
    conn.query_row(
        "select record_json from run_preparations where preparation_id = ?1",
        params![preparation_id],
        |row| row.get::<_, String>(0),
    )
    .optional()
    .map_err(preparation_sqlite_error)?
    .map(|json| serde_json::from_str(&json).map_err(preparation_serde_error))
    .transpose()
}

fn preparation_conflict() -> PreparationError {
    PreparationError::new(
        "preparation.idempotency_conflict",
        "preparation identity was replayed with different input",
    )
}
fn preparation_stale() -> PreparationError {
    PreparationError::new(
        "preparation.state_stale",
        "preparation state changed before persistence",
    )
}
fn preparation_sqlite_error(error: rusqlite::Error) -> PreparationError {
    PreparationError::new("storage.agent_os_state_sqlite", error.to_string())
}
fn preparation_serde_error(error: serde_json::Error) -> PreparationError {
    PreparationError::new("preparation.record_invalid", error.to_string())
}

impl GlobalRunLeaseRepository for SqliteAgentOSStateStore {
    fn acquire_legacy(
        &mut self,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.acquire_global_lease(
            Some(run_id),
            None,
            LLMBindingSchema::LegacyV1,
            host_epoch,
            GlobalRunLeaseState::Active,
            None,
        )
    }

    fn acquire_preparation(
        &mut self,
        preparation_id: &str,
        host_epoch: &str,
        expiration: u64,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.acquire_global_lease(
            None,
            Some(preparation_id),
            LLMBindingSchema::HostSlotV2,
            host_epoch,
            GlobalRunLeaseState::Preparing,
            Some(expiration),
        )
    }

    fn promote_preparation(
        &mut self,
        generation: u64,
        preparation_id: &str,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        let changed = self
            .conn
            .execute(
                "update global_run_lease
             set owner_run_id = ?1, state = 'active', preparation_expiration = null
             where singleton_id = 1 and lease_generation = ?2 and preparation_id = ?3
               and host_process_epoch = ?4 and state = 'preparing'",
                params![run_id, generation.to_string(), preparation_id, host_epoch],
            )
            .map_err(global_sqlite_error)?;
        if changed != 1 {
            return Err(stale());
        }
        self.current_global_run_lease()?.ok_or_else(stale)
    }

    fn begin_release(
        &mut self,
        generation: u64,
        owner_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        let current = self.current_global_run_lease()?.ok_or_else(stale)?;
        if current.generation() != generation
            || current.host_process_epoch() != host_epoch
            || !current.owner_matches(owner_id)
        {
            return Err(stale());
        }
        if current.state() == GlobalRunLeaseState::Releasing {
            return Ok(current);
        }
        let changed = self
            .conn
            .execute(
                "update global_run_lease set state = 'releasing'
             where singleton_id = 1 and lease_generation = ?1 and host_process_epoch = ?2
               and state in ('preparing', 'active')",
                params![generation.to_string(), host_epoch],
            )
            .map_err(global_sqlite_error)?;
        if changed != 1 {
            return Err(stale());
        }
        self.current_global_run_lease()?.ok_or_else(stale)
    }

    fn complete_release(
        &mut self,
        generation: u64,
        host_epoch: &str,
    ) -> Result<(), GlobalRunLeaseError> {
        let changed = self
            .conn
            .execute(
                "delete from global_run_lease
             where singleton_id = 1 and lease_generation = ?1 and host_process_epoch = ?2
               and state = 'releasing'",
                params![generation.to_string(), host_epoch],
            )
            .map_err(global_sqlite_error)?;
        if changed != 1 {
            return Err(stale());
        }
        Ok(())
    }

    fn recover_old_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(global_sqlite_error)?;
        let current = load_global_run_lease(&tx)?;
        let Some(lease) = current else {
            tx.commit().map_err(global_sqlite_error)?;
            return Ok(None);
        };
        if lease.host_process_epoch() == current_host_epoch {
            tx.commit().map_err(global_sqlite_error)?;
            return Ok(None);
        }
        let changed = tx.execute(
            "delete from global_run_lease where singleton_id = 1 and lease_generation = ?1 and host_process_epoch = ?2",
            params![lease.generation().to_string(), lease.host_process_epoch()],
        ).map_err(global_sqlite_error)?;
        if changed != 1 {
            return Err(stale());
        }
        tx.commit().map_err(global_sqlite_error)?;
        Ok(Some(lease))
    }

    fn current_global_run_lease(&self) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
        load_global_run_lease(&self.conn)
    }
}

impl SqliteAgentOSStateStore {
    #[allow(clippy::too_many_arguments)]
    fn acquire_global_lease(
        &mut self,
        run_id: Option<&str>,
        preparation_id: Option<&str>,
        schema: LLMBindingSchema,
        host_epoch: &str,
        state: GlobalRunLeaseState,
        expiration: Option<u64>,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(global_sqlite_error)?;
        if load_global_run_lease(&tx)?.is_some() {
            return Err(busy());
        }
        let last: String = tx.query_row(
            "select cast(last_lease_generation as text) from agent_os_schema_meta where singleton_id = 1",
            [], |row| row.get(0),
        ).map_err(global_sqlite_error)?;
        let generation = last
            .parse::<u64>()
            .map_err(|_| {
                GlobalRunLeaseError::new(
                    "execution.global_run_lease_invalid",
                    "persisted lease generation is invalid",
                )
            })?
            .checked_add(1)
            .ok_or_else(|| {
                GlobalRunLeaseError::new(
                    "execution.global_run_lease_generation_exhausted",
                    "global run lease generation exhausted",
                )
            })?;
        tx.execute(
            "update agent_os_schema_meta set last_lease_generation = ?1 where singleton_id = 1",
            params![generation.to_string()],
        )
        .map_err(global_sqlite_error)?;
        tx.execute(
            "insert into global_run_lease (
               singleton_id, lease_generation, owner_run_id, preparation_id, binding_schema,
               host_process_epoch, state, preparation_expiration
             ) values (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                generation.to_string(),
                run_id,
                preparation_id,
                schema.as_str(),
                host_epoch,
                state.as_str(),
                expiration.map(|value| value.to_string())
            ],
        )
        .map_err(global_sqlite_error)?;
        let lease = load_global_run_lease(&tx)?.ok_or_else(stale)?;
        tx.commit().map_err(global_sqlite_error)?;
        Ok(lease)
    }
}

fn load_global_run_lease(conn: &Connection) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
    conn.query_row(
        "select cast(lease_generation as text), owner_run_id, preparation_id, binding_schema,
                host_process_epoch, state, cast(preparation_expiration as text)
         from global_run_lease where singleton_id = 1",
        [],
        |row| {
            let generation: String = row.get(0)?;
            let schema: String = row.get(3)?;
            let state: String = row.get(5)?;
            let expiration: Option<String> = row.get(6)?;
            Ok(GlobalRunLease::new(
                generation.parse().map_err(sql_conversion)?,
                row.get(1)?,
                row.get(2)?,
                LLMBindingSchema::from_str(&schema).ok_or_else(|| {
                    sql_conversion(std::io::Error::other("invalid binding schema"))
                })?,
                row.get(4)?,
                GlobalRunLeaseState::from_str(&state).map_err(sql_conversion)?,
                expiration
                    .map(|value| value.parse().map_err(sql_conversion))
                    .transpose()?,
            ))
        },
    )
    .optional()
    .map_err(global_sqlite_error)
}

fn sql_conversion(error: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

fn global_sqlite_error(error: rusqlite::Error) -> GlobalRunLeaseError {
    GlobalRunLeaseError::new("storage.agent_os_state_sqlite", error.to_string())
}

fn load_operation_by_key(
    conn: &Connection,
    kind: HostBindingKind,
    key: &str,
) -> Result<Option<HostBindingOperation>, HostBindingError> {
    conn.query_row(
        "select operation_kind, idempotency_key, operation_token, token_digest, subject_id,
                agent_profile_id, agent_profile_revision, llm_slot_id, requirements_hash, state
         from host_binding_operations where operation_kind = ?1 and idempotency_key = ?2",
        params![kind.as_str(), key],
        operation_from_row,
    )
    .optional()
    .map_err(sqlite_error)
}

fn load_operation(
    conn: &Connection,
    token: &str,
) -> Result<Option<HostBindingOperation>, HostBindingError> {
    conn.query_row(
        "select operation_kind, idempotency_key, operation_token, token_digest, subject_id,
                agent_profile_id, agent_profile_revision, llm_slot_id, requirements_hash, state
         from host_binding_operations where operation_token = ?1",
        params![token],
        operation_from_row,
    )
    .optional()
    .map_err(sqlite_error)
}

fn operation_from_row(row: &Row<'_>) -> rusqlite::Result<HostBindingOperation> {
    let kind: String = row.get(0)?;
    let revision: String = row.get(6)?;
    let state: String = row.get(9)?;
    Ok(HostBindingOperation::new(
        HostBindingKind::from_str(&kind).map_err(conversion_error)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        parse_u64(revision)?,
        row.get(7)?,
        row.get(8)?,
        HostBindingOperationState::from_str(&state).map_err(conversion_error)?,
    ))
}

fn load_cross_link(
    conn: &Connection,
    token: &str,
) -> Result<Option<HostBindingCrossLink>, HostBindingError> {
    conn.query_row(
        "select operation_token, token_digest, operation_kind, llm_slot_id, requirements_hash,
                binding_id, binding_revision, binding_hash, staging_receipt_digest, state
         from host_binding_cross_links where operation_token = ?1",
        params![token],
        |row| {
            let operation = HostBindingOperation::new(
                HostBindingKind::from_str(&row.get::<_, String>(2)?).map_err(conversion_error)?,
                String::new(),
                row.get(0)?,
                row.get(1)?,
                String::new(),
                String::new(),
                0,
                row.get(3)?,
                row.get(4)?,
                HostBindingOperationState::Pending,
            );
            let binding = HostBindingTuple::new(
                row.get::<_, String>(5)?,
                parse_u64(row.get(6)?)?,
                row.get::<_, String>(7)?,
            );
            let receipt = HostBindingStagingReceipt::new(
                operation.token_digest(),
                operation.llm_slot_id(),
                operation.requirements_hash(),
                binding.clone(),
                row.get::<_, String>(8)?,
            );
            let commit = HostBindingCommit::new(operation.token(), binding, receipt);
            let state: String = row.get(9)?;
            if HostBindingOperationState::from_str(&state).map_err(conversion_error)?
                != HostBindingOperationState::HostUnbound
            {
                return Err(conversion_error(HostBindingError::new(
                    "host_binding.invalid_persisted_state",
                    "cross-link must be host_unbound",
                )));
            }
            Ok(HostBindingCrossLink::new(&operation, &commit))
        },
    )
    .optional()
    .map_err(sqlite_error)
}

fn parse_u64(value: String) -> rusqlite::Result<u64> {
    value.parse().map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

fn conversion_error(error: HostBindingError) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
}

fn sqlite_error(error: rusqlite::Error) -> HostBindingError {
    HostBindingError::new("storage.agent_os_state_sqlite", error.to_string())
}
