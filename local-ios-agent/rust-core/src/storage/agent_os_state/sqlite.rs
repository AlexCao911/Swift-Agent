use std::path::Path;
use std::time::Duration;

use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::llm_contracts::{
    HostBindingCommit, HostBindingCrossLink, HostBindingError, HostBindingKind,
    HostBindingOperation, HostBindingOperationState, HostBindingStagingReceipt, HostBindingTuple,
    PackageBindingPreparation, ProfilePublishPreparation,
};

use super::in_memory::{conflict, not_found, saga_token, saga_token_digest, validate_commit};
use super::AgentOSStateRepository;

pub struct SqliteAgentOSStateStore {
    conn: Connection,
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
               schema_version integer not null
             );
             insert or ignore into agent_os_schema_meta(singleton_id, schema_version) values (1, 1);

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
               token_digest text not null,
               binding_digest text not null,
               source_revisions_digest text not null,
               state text not null
             );",
        )
        .map_err(sqlite_error)?;
        Ok(Self { conn })
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
            if existing.token() == token {
                return Ok(existing);
            }
            return Err(conflict());
        }
        tx.execute(
            "insert into host_binding_operations (
               operation_token, token_digest, operation_kind, idempotency_key, subject_id,
               agent_profile_id, agent_profile_revision, llm_slot_id, requirements_hash, state
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'pending')",
            params![
                token,
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
        let operation = load_operation(&tx, &token)?.ok_or_else(not_found)?;
        tx.commit().map_err(sqlite_error)?;
        Ok(operation)
    }

    fn commit_operation(
        &mut self,
        expected_kind: HostBindingKind,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let tx = self.conn.transaction().map_err(sqlite_error)?;
        let operation = load_operation(&tx, request.token())?.ok_or_else(not_found)?;
        validate_commit(expected_kind, &operation, &request)?;
        let expected = HostBindingCrossLink::new(&operation, &request);
        if let Some(existing) = load_cross_link(&tx, request.token())? {
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
                operation.token(),
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
                params![operation.token()],
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

impl AgentOSStateRepository for SqliteAgentOSStateStore {
    fn prepare_profile_publish(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let token = saga_token(HostBindingKind::ProfilePublish, &request)?;
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
        let token = saga_token(HostBindingKind::PackageBinding, &request)?;
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
        load_cross_link(&self.conn, operation_token)
    }
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
