use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use sha2::{Digest, Sha256};

use crate::execution::{ExecutionEvent, ExecutionEventRepository};
use crate::llm_contracts::{
    GlobalRunLease, GlobalRunLeaseError, HostBindingActivationConfirmation, HostBindingCommit,
    HostBindingCrossLink, HostBindingError, HostBindingOperation, HostCommandAcknowledgement,
    HostCommandCopyReceipt, HostRunHandle, HostSessionCloseDisposition, HostSessionRecord,
    HostWorkerRecord, LLMEventEnvelope, LLMEventReceipt, LLMEventReceiptDisposition,
    LLMEventSubmissionResult, LogicalRunOutcome, PackageBindingPreparation, PreparationError,
    PreparationReconciliation, PreparedSessionCleanupAcknowledgement,
    PreparedSessionCleanupIdentity, ProfilePublishPreparation, ResourceLifecycle,
    RunPreparationRecord, RunPreparationState,
};

use super::agent_os_state::{
    AgentOSStateRepository, GlobalRunLeaseRepository, PreparedRunConsumption,
    RunPreparationRepository, SharedAgentOSStateStore, SqliteAgentOSStateStore,
};
use super::runtime_state::{
    apply_command_acknowledgement_state, close_command_for, conflict, contract_error, not_found,
    poisoned, reconciliation_conflict, transaction_failed, validate_ack,
    validate_command_for_worker, validate_transition, validate_worker_session,
};
use super::{
    HostCommandOutboxRow, HostCommandOutboxStatus, PreparedHostRunCommit,
    RuntimeAggregateFailurePoint, RuntimeAggregateInspection, RuntimeStateError, RuntimeTransition,
    UnifiedRuntimeStateRepository,
};

const RUNTIME_STATE_SCHEMA_VERSION: u32 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeStateMigrationFailurePoint {
    AfterLegacyCopy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MigrationState {
    Pending,
    UnifiedV2Active,
}

impl MigrationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::UnifiedV2Active => "unified_v2_active",
        }
    }

    fn from_str(value: &str) -> Result<Self, RuntimeStateError> {
        match value {
            "pending" => Ok(Self::Pending),
            "unified_v2_active" => Ok(Self::UnifiedV2Active),
            _ => Err(RuntimeStateError::new(
                "runtime_state.migration_state_invalid",
                format!("unknown migration state: {value}"),
            )),
        }
    }
}

#[derive(Clone)]
pub struct SqliteRuntimeStateStore {
    inner: Arc<Mutex<SqliteAgentOSStateStore>>,
    failure: Arc<Mutex<Option<RuntimeAggregateFailurePoint>>>,
    path: Arc<PathBuf>,
    execution_subscribers: Arc<Mutex<BTreeMap<String, Vec<Sender<ExecutionEvent>>>>>,
}

impl fmt::Debug for SqliteRuntimeStateStore {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SqliteRuntimeStateStore")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl SqliteRuntimeStateStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, RuntimeStateError> {
        Self::open_internal(path.as_ref(), None)
    }

    pub fn open_with_migration_failure(
        path: impl AsRef<Path>,
        failure: RuntimeStateMigrationFailurePoint,
    ) -> Result<Self, RuntimeStateError> {
        Self::open_internal(path.as_ref(), Some(failure))
    }

    pub fn open_in_memory() -> Result<Self, RuntimeStateError> {
        let store = SqliteAgentOSStateStore::open_in_memory().map_err(agent_os_error)?;
        initialize_connection(store.connection())?;
        activate_without_sidecar(store.connection())?;
        Ok(Self {
            inner: Arc::new(Mutex::new(store)),
            failure: Arc::new(Mutex::new(None)),
            path: Arc::new(PathBuf::from(":memory:")),
            execution_subscribers: Arc::new(Mutex::new(BTreeMap::new())),
        })
    }

    fn open_internal(
        path: &Path,
        migration_failure: Option<RuntimeStateMigrationFailurePoint>,
    ) -> Result<Self, RuntimeStateError> {
        let probe = Connection::open(path).map_err(sqlite_error)?;
        reject_future_schema(&probe)?;
        drop(probe);
        let mut store = SqliteAgentOSStateStore::open(path).map_err(agent_os_error)?;
        initialize_connection(store.connection())?;
        migrate_sidecar_if_needed(store.connection_mut(), path, migration_failure)?;
        Ok(Self {
            inner: Arc::new(Mutex::new(store)),
            failure: Arc::new(Mutex::new(None)),
            path: Arc::new(path.to_path_buf()),
            execution_subscribers: Arc::new(Mutex::new(BTreeMap::new())),
        })
    }

    pub fn inject_failure(&self, point: RuntimeAggregateFailurePoint) {
        *self
            .failure
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(point);
    }

    pub fn agent_os_state(&self) -> SharedAgentOSStateStore {
        SharedAgentOSStateStore::new(SqliteRuntimeAgentOSView {
            inner: self.inner.clone(),
        })
    }

    pub fn conversation_event_store(
        &self,
    ) -> Result<crate::memory::SqliteEventStore, crate::core::AgentError> {
        crate::memory::SqliteEventStore::from_unified_owner(self.inner.clone())
    }

    pub fn migration_state(&self) -> Result<MigrationState, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        let state: String = store
            .connection()
            .query_row(
                "select migration_state from runtime_state_meta where singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)?;
        MigrationState::from_str(&state)
    }

    pub fn schema_version(&self) -> Result<u32, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        store
            .connection()
            .query_row(
                "select schema_version from runtime_state_meta where singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn migration_source_digest(&self) -> Result<Option<String>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        store
            .connection()
            .query_row(
                "select migration_source_digest from runtime_state_meta where singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .map_err(sqlite_error)
    }

    pub fn global_lease_generation(&self) -> Result<Option<u64>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        let value: Option<String> = store
            .connection()
            .query_row(
                "select cast(lease_generation as text) from global_run_lease where singleton_id = 1",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)?;
        value
            .map(|value| {
                value.parse::<u64>().map_err(|_| {
                    RuntimeStateError::new(
                        "runtime_state.lease_invalid",
                        "lease generation is not a canonical unsigned integer",
                    )
                })
            })
            .transpose()
    }

    fn take_failure(&self, point: RuntimeAggregateFailurePoint) -> Result<(), RuntimeStateError> {
        let mut failure = self
            .failure
            .lock()
            .unwrap_or_else(|value| value.into_inner());
        if failure.as_ref() == Some(&point) {
            *failure = None;
            return Err(transaction_failed());
        }
        Ok(())
    }
}

impl UnifiedRuntimeStateRepository for SqliteRuntimeStateStore {
    fn insert_worker_and_session(
        &self,
        worker: HostWorkerRecord,
        session: HostSessionRecord,
    ) -> Result<(), RuntimeStateError> {
        validate_worker_session(&worker, &session)?;
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        insert_worker(&transaction, &worker)?;
        insert_session(&transaction, &session)?;
        transaction.commit().map_err(sqlite_error)
    }

    fn commit_prepared_host_run(
        &self,
        commit: PreparedHostRunCommit,
    ) -> Result<(), RuntimeStateError> {
        validate_worker_session(&commit.worker, &commit.session)?;
        validate_command_for_worker(&commit.worker, &commit.first_command)?;
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        consume_preparation_and_promote_lease(&transaction, &commit)?;
        transaction
            .execute(
                "insert into host_committed_preparations(
                   preparation_id, consumed_token_digest, lease_generation, run_id
                 ) values (?1, ?2, ?3, ?4)",
                params![
                    commit.preparation_id,
                    commit.consumed_token_digest,
                    commit.lease_generation.to_string(),
                    commit.worker.run_id()
                ],
            )
            .map_err(sqlite_error)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterPreparationCommit)?;
        transaction
            .execute(
                "insert into host_run_snapshots(run_id, snapshot_digest, snapshot_json)
                 values (?1, ?2, ?3)",
                params![
                    commit.worker.run_id(),
                    commit.snapshot_digest,
                    commit.snapshot_json
                ],
            )
            .map_err(sqlite_error)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterSnapshotWrite)?;
        transaction
            .execute(
                "insert into host_agent_events(run_id, sequence, code, payload)
                 values (?1, 1, ?2, ?3)",
                params![
                    commit.worker.run_id(),
                    commit.initial_event_code,
                    commit.initial_event_payload
                ],
            )
            .map_err(sqlite_error)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterAgentEventWrite)?;
        insert_worker(&transaction, &commit.worker)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterWorkerWrite)?;
        insert_session(&transaction, &commit.session)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterSessionWrite)?;
        insert_outbox(
            &transaction,
            &HostCommandOutboxRow::pending(commit.first_command),
        )?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterOutboxWrite)?;
        transaction.commit().map_err(sqlite_error)
    }

    fn transition_and_enqueue(
        &self,
        transition: RuntimeTransition,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        let current =
            load_worker(&transaction, transition.next_worker().run_id())?.ok_or_else(not_found)?;
        validate_transition(&current, &transition)?;
        let next = transition
            .next_worker()
            .clone()
            .with_expected_command_sequence(current.expected_command_sequence() + 1);
        update_worker(&transaction, transition.expected_worker_revision(), &next)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterWorkerWrite)?;
        let row = HostCommandOutboxRow::pending(transition.command().clone());
        insert_outbox(&transaction, &row)?;
        self.take_failure(RuntimeAggregateFailurePoint::AfterOutboxWrite)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(row)
    }

    fn record_copy_receipt_at(
        &self,
        command_id: &str,
        receipt: HostCommandCopyReceipt,
        now_millis: u64,
        acknowledgement_timeout: std::time::Duration,
        redispatch_interval: std::time::Duration,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        let row = load_outbox(&transaction, command_id)?.ok_or_else(not_found)?;
        if !matches!(
            row.status(),
            HostCommandOutboxStatus::PendingCopy | HostCommandOutboxStatus::Copied
        ) {
            return Ok(row);
        }
        let row = row.with_timed_copy_receipt(
            receipt,
            now_millis,
            acknowledgement_timeout,
            redispatch_interval,
        );
        update_outbox(&transaction, &row)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(row)
    }

    fn fail_command_acknowledgement_timeout(
        &self,
        command_id: &str,
    ) -> Result<HostWorkerRecord, RuntimeStateError> {
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        let row = load_outbox(&transaction, command_id)?.ok_or_else(not_found)?;
        if row.status() == HostCommandOutboxStatus::TimedOut {
            return load_worker(&transaction, row.run_id())?.ok_or_else(not_found);
        }
        if !matches!(
            row.status(),
            HostCommandOutboxStatus::PendingCopy | HostCommandOutboxStatus::Copied
        ) {
            return Err(conflict());
        }
        let worker = load_worker(&transaction, row.run_id())?.ok_or_else(not_found)?;
        let kind = row
            .payload()
            .map(crate::llm_contracts::HostCommandEnvelope::kind)
            .ok_or_else(conflict)?;
        let close_command = (!matches!(kind, crate::llm_contracts::HostCommandKind::CloseSession))
            .then(|| close_command_for(&row, &worker))
            .transpose()?;
        let lifecycle = if close_command.is_some() {
            ResourceLifecycle::AwaitingCloseCommandAck
        } else {
            ResourceLifecycle::Quarantined {
                code: "llm.command.ack_timeout".into(),
            }
        };
        let failed = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(None)
            .with_logical_outcome(LogicalRunOutcome::Failed {
                code: "llm.command.ack_timeout".into(),
            })
            .with_resource_lifecycle(lifecycle.clone())
            .with_expected_command_sequence(
                worker.expected_command_sequence() + u64::from(close_command.is_some()),
            );
        update_worker(&transaction, worker.revision(), &failed)?;
        let session = load_session(&transaction, row.session_handle())?.ok_or_else(not_found)?;
        update_session(&transaction, &session.with_resource_lifecycle(lifecycle))?;
        update_outbox(&transaction, &row.timed_out())?;
        if let Some(close_command) = close_command {
            insert_outbox(&transaction, &HostCommandOutboxRow::pending(close_command))?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(failed)
    }

    fn acknowledge_command(
        &self,
        acknowledgement: &HostCommandAcknowledgement,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        let row = load_outbox(&transaction, acknowledgement.command_id())?.ok_or_else(not_found)?;
        validate_ack(&row, acknowledgement)?;
        if let Some(existing) = row.acknowledgement() {
            return if existing == acknowledgement {
                Ok(row)
            } else {
                Err(conflict())
            };
        }
        let worker = load_worker(&transaction, row.run_id())?.ok_or_else(not_found)?;
        let session = load_session(&transaction, row.session_handle())?.ok_or_else(not_found)?;
        let (next_worker, next_session, close_command) =
            apply_command_acknowledgement_state(&row, acknowledgement, &worker, &session)?;
        let row = row.with_acknowledgement(acknowledgement.clone());
        update_outbox(&transaction, &row)?;
        update_worker(&transaction, worker.revision(), &next_worker)?;
        update_session(&transaction, &next_session)?;
        if let Some(close_command) = close_command {
            insert_outbox(&transaction, &HostCommandOutboxRow::pending(close_command))?;
        }
        transaction.commit().map_err(sqlite_error)?;
        Ok(row)
    }

    fn apply_event_transactionally(
        &self,
        event: &LLMEventEnvelope,
        result: LLMEventSubmissionResult,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
        if result == LLMEventSubmissionResult::Duplicate {
            return self.event_receipt(event.session_handle(), event.event_sequence());
        }
        if !matches!(
            result,
            LLMEventSubmissionResult::Accepted
                | LLMEventSubmissionResult::TurnTerminal
                | LLMEventSubmissionResult::GenerationTerminal
        ) {
            return Ok(None);
        }
        if event.expected_digest().map_err(contract_error)? != event.event_envelope_digest() {
            return Err(RuntimeStateError::new(
                "llm.event.invalid_envelope",
                "event envelope digest mismatch",
            ));
        }
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        let worker = load_worker(&transaction, event.run_id())?.ok_or_else(not_found)?;
        if worker.session_handle() != event.session_handle()
            || worker.host_process_epoch() != event.host_process_epoch()
            || worker.expected_event_sequence() != event.event_sequence()
        {
            return Err(RuntimeStateError::new(
                "llm.event.identity_or_sequence_conflict",
                "event does not match worker identity and expected sequence",
            ));
        }
        let disposition = if result == LLMEventSubmissionResult::Accepted {
            LLMEventReceiptDisposition::Accepted
        } else {
            LLMEventReceiptDisposition::TerminallyIgnored
        };
        let receipt = LLMEventReceipt::new(
            event.run_id(),
            event.session_handle(),
            event.host_process_epoch(),
            event.event_sequence(),
            event.event_id(),
            event.event_envelope_digest(),
            disposition,
        )
        .map_err(contract_error)?;
        insert_event_receipt(&transaction, &receipt)?;
        let next = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_expected_event_sequence(worker.expected_event_sequence() + 1);
        update_worker(&transaction, worker.revision(), &next)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(Some(receipt))
    }

    fn recover_run_for_epoch(
        &self,
        run_id: &str,
        current_epoch: &str,
    ) -> Result<HostWorkerRecord, RuntimeStateError> {
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        let transaction = store
            .connection_mut()
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        let worker = load_worker(&transaction, run_id)?.ok_or_else(not_found)?;
        if worker.host_process_epoch() == current_epoch {
            transaction.commit().map_err(sqlite_error)?;
            return Ok(worker);
        }
        let recovered = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(None)
            .with_logical_outcome(LogicalRunOutcome::Interrupted {
                code: "host_epoch_ended".into(),
            })
            .with_resource_lifecycle(ResourceLifecycle::Closed {
                disposition: HostSessionCloseDisposition::EpochEnded,
            });
        update_worker(&transaction, worker.revision(), &recovered)?;
        let session = load_session(&transaction, worker.session_handle())?.ok_or_else(not_found)?;
        update_session(
            &transaction,
            &session
                .clone()
                .with_resource_lifecycle(ResourceLifecycle::Closed {
                    disposition: HostSessionCloseDisposition::EpochEnded,
                }),
        )?;
        let next_event_sequence: u64 = transaction
            .query_row(
                "select coalesce(max(cast(sequence as integer)), 0) + 1
                 from host_agent_events where run_id = ?1",
                params![run_id],
                |row| row.get(0),
            )
            .map_err(sqlite_error)?;
        transaction
            .execute(
                "insert into host_agent_events(run_id, sequence, code, payload)
                 values (?1, ?2, 'run.interrupted', 'host_epoch_ended')",
                params![run_id, next_event_sequence.to_string()],
            )
            .map_err(sqlite_error)?;
        let pending_json = {
            let mut statement = transaction
                .prepare(
                    "select record_json from host_command_outbox
                     where run_id = ?1 and status in ('pending_copy', 'copied')",
                )
                .map_err(sqlite_error)?;
            let rows = statement
                .query_map(params![run_id], |row| row.get::<_, String>(0))
                .map_err(sqlite_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(sqlite_error)?;
            rows
        };
        for json in pending_json {
            let row: HostCommandOutboxRow = decode(&json)?;
            update_outbox(&transaction, &row.cancelled())?;
        }
        transaction
            .execute(
                "delete from global_run_lease where singleton_id = 1 and owner_run_id = ?1
                 and host_process_epoch = ?2",
                params![run_id, worker.host_process_epoch()],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)?;
        Ok(recovered)
    }

    fn host_worker(&self, run_id: &str) -> Result<Option<HostWorkerRecord>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        load_worker(store.connection(), run_id)
    }

    fn host_session(
        &self,
        session_handle: &str,
    ) -> Result<Option<HostSessionRecord>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        load_session(store.connection(), session_handle)
    }

    fn run_snapshot_json(&self, run_id: &str) -> Result<Option<String>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        store
            .connection()
            .query_row(
                "select snapshot_json from host_run_snapshots where run_id = ?1",
                params![run_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)
    }

    fn committed_run_handle(
        &self,
        preparation_id: &str,
        token_digest: &str,
    ) -> Result<Option<HostRunHandle>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        let committed: Option<(String, String, String, String)> = store
            .connection()
            .query_row(
                "select committed.consumed_token_digest, committed.run_id,
                        outbox.session_handle, outbox.command_id
                 from host_committed_preparations committed
                 join host_command_outbox outbox on outbox.run_id = committed.run_id
                 where committed.preparation_id = ?1 and outbox.command_sequence = '1'",
                params![preparation_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()
            .map_err(sqlite_error)?;
        let Some((consumed_digest, run_id, session_handle, command_id)) = committed else {
            return Ok(None);
        };
        if consumed_digest != token_digest {
            return Err(reconciliation_conflict());
        }
        Ok(Some(HostRunHandle::new(run_id, session_handle, command_id)))
    }

    fn reconcile_preparation(
        &self,
        preparation_id: &str,
        proposed_run_id: &str,
        token_digest: &str,
    ) -> Result<PreparationReconciliation, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        let connection = store.connection();
        let committed: Option<(String, String, String, String)> = connection
            .query_row(
                "select committed.consumed_token_digest, committed.run_id,
                        outbox.session_handle, outbox.command_id
                 from host_committed_preparations committed
                 join host_command_outbox outbox on outbox.run_id = committed.run_id
                 where committed.preparation_id = ?1 and outbox.command_sequence = '1'",
                params![preparation_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()
            .map_err(sqlite_error)?;
        if let Some((consumed_digest, run_id, session_handle, command_id)) = committed {
            if run_id != proposed_run_id || consumed_digest != token_digest {
                return Err(reconciliation_conflict());
            }
            return Ok(PreparationReconciliation::Committed {
                handle: HostRunHandle::new(run_id, session_handle, command_id),
            });
        }

        let record_json: Option<String> = connection
            .query_row(
                "select record_json from run_preparations where preparation_id = ?1",
                params![preparation_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(sqlite_error)?;
        let record: RunPreparationRecord = record_json
            .map(|json| decode(&json))
            .transpose()?
            .ok_or_else(reconciliation_conflict)?;
        if record.preview().proposed_run_id() != proposed_run_id
            || record.preview().token_digest() != token_digest
        {
            return Err(reconciliation_conflict());
        }
        match record.state() {
            RunPreparationState::Pending | RunPreparationState::Registered => {
                Ok(PreparationReconciliation::Pending)
            }
            RunPreparationState::Aborting | RunPreparationState::Closed => record
                .cleanup()
                .map(PreparedSessionCleanupIdentity::from_cleanup)
                .map(|cleanup_identity| PreparationReconciliation::Aborting { cleanup_identity })
                .ok_or_else(not_found),
        }
    }

    fn host_command(
        &self,
        command_id: &str,
    ) -> Result<Option<HostCommandOutboxRow>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        load_outbox(store.connection(), command_id)
    }

    fn pending_host_commands(&self) -> Result<Vec<HostCommandOutboxRow>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        let mut statement = store
            .connection()
            .prepare(
                "select record_json from host_command_outbox
                 where status in ('pending_copy', 'copied')
                 order by session_handle, command_sequence",
            )
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(sqlite_error)?
            .map(|row| decode(&row.map_err(sqlite_error)?))
            .collect();
        rows
    }

    fn event_receipt(
        &self,
        session_handle: &str,
        event_sequence: u64,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        store
            .connection()
            .query_row(
                "select record_json from llm_event_receipts
                 where session_handle = ?1 and event_sequence = ?2",
                params![session_handle, event_sequence.to_string()],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(sqlite_error)?
            .map(|json| decode(&json))
            .transpose()
    }

    fn inspect_v2_aggregate(
        &self,
        preparation_id: &str,
        run_id: &str,
        session_handle: &str,
    ) -> Result<RuntimeAggregateInspection, RuntimeStateError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        let connection = store.connection();
        Ok(RuntimeAggregateInspection {
            committed_preparation: row_exists(
                &connection,
                "host_committed_preparations",
                "preparation_id",
                preparation_id,
            )?,
            snapshot: row_exists(&connection, "host_run_snapshots", "run_id", run_id)?,
            agent_event: row_exists(&connection, "host_agent_events", "run_id", run_id)?,
            worker: row_exists(&connection, "host_workers", "run_id", run_id)?,
            session: row_exists(
                &connection,
                "host_sessions",
                "session_handle",
                session_handle,
            )?,
            outbox: row_exists(&connection, "host_command_outbox", "run_id", run_id)?,
        })
    }
}

fn consume_preparation_and_promote_lease(
    transaction: &Transaction<'_>,
    commit: &PreparedHostRunCommit,
) -> Result<(), RuntimeStateError> {
    let persisted: Option<(String, String, String, String, String)> = transaction
        .query_row(
            "select proposed_run_id, token_digest, lease_generation, state, record_json
             from run_preparations where preparation_id = ?1",
            params![commit.preparation_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()
        .map_err(sqlite_error)?;
    let Some((proposed_run_id, token_digest, lease_generation, state, record_json)) = persisted
    else {
        return Err(RuntimeStateError::new(
            "runtime_state.preparation_missing",
            "Phase C requires a durable registered preparation",
        ));
    };
    let record: RunPreparationRecord = decode(&record_json)?;
    let registration = record.registration().ok_or_else(|| {
        RuntimeStateError::new(
            "runtime_state.preparation_not_registered",
            "Phase C requires a registered prepared session",
        )
    })?;
    let valid = proposed_run_id == commit.worker.run_id()
        && token_digest == commit.consumed_token_digest
        && lease_generation == commit.lease_generation.to_string()
        && state == "registered"
        && registration.session_handle() == commit.session.session_handle()
        && registration.host_process_epoch() == commit.worker.host_process_epoch()
        && registration.binding_id() == commit.session.binding_id()
        && registration.binding_revision() == commit.session.binding_revision()
        && registration.binding_hash() == commit.session.binding_hash();
    if !valid {
        return Err(RuntimeStateError::new(
            "runtime_state.preparation_cas_conflict",
            "preparation, registration, token, lease, or host identity changed before Phase C",
        ));
    }
    let lease_matches: bool = transaction
        .query_row(
            "select exists(
               select 1 from global_run_lease where singleton_id = 1
                 and lease_generation = ?1 and preparation_id = ?2
                 and owner_run_id is null and binding_schema = 'host_slot_v2'
                 and host_process_epoch = ?3 and state = 'preparing'
             )",
            params![
                commit.lease_generation.to_string(),
                commit.preparation_id,
                commit.worker.host_process_epoch()
            ],
            |row| row.get(0),
        )
        .map_err(sqlite_error)?;
    if !lease_matches {
        return Err(RuntimeStateError::new(
            "runtime_state.lease_cas_conflict",
            "global lease changed before Phase C",
        ));
    }
    let changed = transaction
        .execute(
            "update global_run_lease set owner_run_id = ?1, state = 'active',
               preparation_expiration = null
             where singleton_id = 1 and lease_generation = ?2 and preparation_id = ?3
               and host_process_epoch = ?4 and state = 'preparing'",
            params![
                commit.worker.run_id(),
                commit.lease_generation.to_string(),
                commit.preparation_id,
                commit.worker.host_process_epoch()
            ],
        )
        .map_err(sqlite_error)?;
    if changed != 1 {
        return Err(RuntimeStateError::new(
            "runtime_state.lease_cas_conflict",
            "global lease promotion lost its compare-and-swap",
        ));
    }
    transaction
        .execute(
            "delete from run_preparations where preparation_id = ?1 and token_digest = ?2
             and lease_generation = ?3 and state = 'registered'",
            params![
                commit.preparation_id,
                commit.consumed_token_digest,
                commit.lease_generation.to_string()
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

impl ExecutionEventRepository for SqliteRuntimeStateStore {
    fn append(&self, run_id: String, code: String, payload: String) -> ExecutionEvent {
        let event = {
            let mut store = self
                .inner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let transaction = store
                .connection_mut()
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .expect("unified execution event transaction must begin");
            let next_sequence: u64 = transaction
                .query_row(
                    "select coalesce(max(cast(sequence as integer)), 0) + 1
                     from host_agent_events where run_id = ?1",
                    params![run_id],
                    |row| row.get(0),
                )
                .expect("unified execution event sequence must be readable");
            transaction
                .execute(
                    "insert into host_agent_events(run_id, sequence, code, payload)
                     values (?1, ?2, ?3, ?4)",
                    params![run_id, next_sequence.to_string(), code, payload],
                )
                .expect("unified execution event must be appendable");
            transaction
                .commit()
                .expect("unified execution event transaction must commit");
            ExecutionEvent::persisted(run_id.clone(), next_sequence, code, payload)
        };
        self.execution_subscribers
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entry(run_id)
            .or_default()
            .retain(|sender| sender.send(event.clone()).is_ok());
        event
    }

    fn replay_after(&self, run_id: &str, from_sequence: u64) -> Vec<ExecutionEvent> {
        let store = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut statement = store
            .connection()
            .prepare(
                "select cast(sequence as integer), code, payload
                 from host_agent_events where run_id = ?1 and cast(sequence as integer) > ?2
                 order by cast(sequence as integer)",
            )
            .expect("unified execution events must be queryable");
        statement
            .query_map(params![run_id, from_sequence], |row| {
                Ok(ExecutionEvent::persisted(
                    run_id,
                    row.get(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .expect("unified execution events must be readable")
            .map(|row| row.expect("unified execution event row must be valid"))
            .collect()
    }

    fn subscribe_live(&self, run_id: &str) -> Receiver<ExecutionEvent> {
        let (sender, receiver) = mpsc::channel();
        self.execution_subscribers
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entry(run_id.to_string())
            .or_default()
            .push(sender);
        receiver
    }
}

#[derive(Clone)]
struct SqliteRuntimeAgentOSView {
    inner: Arc<Mutex<SqliteAgentOSStateStore>>,
}

impl AgentOSStateRepository for SqliteRuntimeAgentOSView {
    fn prepare_profile_publish(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .prepare_profile_publish(request)
    }

    fn commit_profile_publish(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .commit_profile_publish(request)
    }

    fn begin_package_binding(
        &mut self,
        request: PackageBindingPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .begin_package_binding(request)
    }

    fn attach_host_binding(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .attach_host_binding(request)
    }

    fn cross_link(
        &self,
        operation_token: &str,
    ) -> Result<Option<HostBindingCrossLink>, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .cross_link(operation_token)
    }

    fn matching_cross_link(
        &self,
        agent_profile_id: &str,
        agent_profile_revision: u64,
        llm_slot_id: &str,
        requirements_hash: &str,
        binding_id: &str,
        binding_revision: u64,
        binding_hash: &str,
    ) -> Result<Option<HostBindingCrossLink>, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .matching_cross_link(
                agent_profile_id,
                agent_profile_revision,
                llm_slot_id,
                requirements_hash,
                binding_id,
                binding_revision,
                binding_hash,
            )
    }

    fn activate_matching_cross_link(
        &mut self,
        confirmation: &HostBindingActivationConfirmation,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.inner
            .lock()
            .map_err(|_| host_binding_poisoned())?
            .activate_matching_cross_link(confirmation)
    }
}

impl GlobalRunLeaseRepository for SqliteRuntimeAgentOSView {
    fn acquire_legacy(
        &mut self,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .acquire_legacy(run_id, host_epoch)
    }

    fn acquire_preparation(
        &mut self,
        preparation_id: &str,
        host_epoch: &str,
        expiration: u64,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .acquire_preparation(preparation_id, host_epoch, expiration)
    }

    fn promote_preparation(
        &mut self,
        generation: u64,
        preparation_id: &str,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .promote_preparation(generation, preparation_id, run_id, host_epoch)
    }

    fn begin_release(
        &mut self,
        generation: u64,
        owner_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .begin_release(generation, owner_id, host_epoch)
    }

    fn complete_release(
        &mut self,
        generation: u64,
        host_epoch: &str,
    ) -> Result<(), GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .complete_release(generation, host_epoch)
    }

    fn recover_old_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .recover_old_epoch(current_host_epoch)
    }

    fn current_global_run_lease(&self) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
        self.inner
            .lock()
            .map_err(|_| lease_poisoned())?
            .current_global_run_lease()
    }
}

impl RunPreparationRepository for SqliteRuntimeAgentOSView {
    fn consume_registered_preparation_and_promote(
        &mut self,
        request: &PreparedRunConsumption,
    ) -> Result<(), PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .consume_registered_preparation_and_promote(request)
    }

    fn create_preparation_and_acquire_lease(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .create_preparation_and_acquire_lease(record)
    }

    fn create_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .create_run_preparation(record)
    }

    fn save_run_preparation(
        &mut self,
        expected_state: RunPreparationState,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .save_run_preparation(expected_state, record)
    }

    fn renew_preparation_and_lease(
        &mut self,
        expected_state: RunPreparationState,
        expected_token_generation: u64,
        expected_token_digest: &str,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .renew_preparation_and_lease(
                expected_state,
                expected_token_generation,
                expected_token_digest,
                record,
            )
    }

    fn recover_preparations_for_new_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Vec<String>, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .recover_preparations_for_new_epoch(current_host_epoch)
    }

    fn abort_run_preparation(
        &mut self,
        record: RunPreparationRecord,
        has_registered_session: bool,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .abort_run_preparation(record, has_registered_session)
    }

    fn acknowledge_prepared_cleanup(
        &mut self,
        record: RunPreparationRecord,
        acknowledgement: &PreparedSessionCleanupAcknowledgement,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .acknowledge_prepared_cleanup(record, acknowledgement)
    }

    fn close_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .close_run_preparation(record)
    }

    fn run_preparation(
        &self,
        preparation_id: &str,
    ) -> Result<Option<RunPreparationRecord>, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .run_preparation(preparation_id)
    }

    fn active_run_preparation(&self) -> Result<Option<RunPreparationRecord>, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .active_run_preparation()
    }

    fn list_run_preparations(&self) -> Result<Vec<RunPreparationRecord>, PreparationError> {
        self.inner
            .lock()
            .map_err(|_| preparation_poisoned())?
            .list_run_preparations()
    }
}

fn host_binding_poisoned() -> HostBindingError {
    HostBindingError::new(
        "host_binding.store_poisoned",
        "unified runtime state mutex is poisoned",
    )
}

fn lease_poisoned() -> GlobalRunLeaseError {
    GlobalRunLeaseError::new(
        "execution.global_run_lease_store_poisoned",
        "unified runtime state mutex is poisoned",
    )
}

fn preparation_poisoned() -> PreparationError {
    PreparationError::new(
        "preparation.store_poisoned",
        "unified runtime state mutex is poisoned",
    )
}

fn row_exists(
    connection: &Connection,
    table: &str,
    column: &str,
    value: &str,
) -> Result<bool, RuntimeStateError> {
    connection
        .query_row(
            &format!("select exists(select 1 from {table} where {column} = ?1)"),
            params![value],
            |row| row.get(0),
        )
        .map_err(sqlite_error)
}

fn reject_future_schema(connection: &Connection) -> Result<(), RuntimeStateError> {
    let exists: bool = connection
        .query_row(
            "select exists(select 1 from sqlite_master where type = 'table' and name = 'runtime_state_meta')",
            [],
            |row| row.get(0),
        )
        .map_err(sqlite_error)?;
    if !exists {
        return Ok(());
    }
    let version: u32 = connection
        .query_row(
            "select schema_version from runtime_state_meta where singleton_id = 1",
            [],
            |row| row.get(0),
        )
        .map_err(sqlite_error)?;
    if version > RUNTIME_STATE_SCHEMA_VERSION {
        return Err(RuntimeStateError::new(
            "runtime_state.schema_future",
            format!("future runtime state schema version: {version}"),
        ));
    }
    if !matches!(version, 1 | RUNTIME_STATE_SCHEMA_VERSION) {
        return Err(RuntimeStateError::new(
            "runtime_state.schema_unsupported",
            format!("unsupported runtime state schema version: {version}"),
        ));
    }
    Ok(())
}

fn initialize_connection(connection: &Connection) -> Result<(), RuntimeStateError> {
    connection
        .execute_batch(
            "pragma foreign_keys = on;
             create table if not exists runtime_state_meta (
               singleton_id integer primary key check(singleton_id = 1),
               schema_version integer not null,
               migration_state text not null,
               migration_source_digest text
             );
             insert or ignore into runtime_state_meta values (1, 2, 'pending', null);

             create table if not exists agent_os_schema_meta (
               singleton_id integer primary key check (singleton_id = 1),
               schema_version integer not null,
               last_lease_generation integer not null default 0
             );
             insert or ignore into agent_os_schema_meta values (1, 1, 0);
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
               operation_token text primary key, token_digest text not null,
               operation_kind text not null, idempotency_key text not null,
               subject_id text not null, agent_profile_id text not null,
               agent_profile_revision text not null, llm_slot_id text not null,
               requirements_hash text not null, state text not null,
               unique(operation_kind, idempotency_key)
             );
             create table if not exists host_binding_cross_links (
               operation_token text primary key, token_digest text not null,
               operation_kind text not null, llm_slot_id text not null,
               requirements_hash text not null, binding_id text not null,
               binding_revision text not null, binding_hash text not null,
               staging_receipt_digest text not null, state text not null
             );
             create table if not exists run_preparations (
               preparation_id text primary key, idempotency_key text not null unique,
               proposed_run_id text not null unique, token_generation text not null,
               token_digest text not null, binding_digest text not null,
               source_revisions_digest text not null, host_process_epoch text not null,
               lease_generation text not null, state text not null, record_json text not null
             );
             create table if not exists preparation_cleanup_outbox (
               cleanup_command_id text primary key, preparation_id text not null unique,
               cleanup_sequence text not null, registration_digest text not null,
               command_digest text not null, state text not null, record_json text not null
             );
             create table if not exists preparation_cleanup_receipts (
               cleanup_command_id text primary key, preparation_id text not null unique,
               receipt_digest text not null, close_disposition text not null,
               record_json text not null
             );

             create table if not exists host_workers (
               run_id text primary key, session_handle text not null unique,
               host_process_epoch text not null, revision text not null,
               execution_phase text, logical_outcome text not null,
               resource_lifecycle text not null, expected_command_sequence text not null,
               expected_event_sequence text not null, record_json text not null
             );
             create table if not exists host_sessions (
               session_handle text primary key, run_id text not null unique,
               host_process_epoch text not null, binding_id text not null,
               binding_revision text not null, binding_hash text not null,
               resource_lifecycle text not null, record_json text not null
             );
             create table if not exists host_command_outbox (
               command_id text primary key, run_id text not null,
               session_handle text not null, host_process_epoch text not null,
               command_sequence text not null, command_envelope_digest text not null,
               status text not null, payload_json text, record_json text not null,
               unique(session_handle, command_sequence)
             );
             create table if not exists llm_event_receipts (
               session_handle text not null, event_sequence text not null,
               event_id text not null, event_envelope_digest text not null,
               disposition text not null, receipt_digest text not null,
               record_json text not null,
               primary key(session_handle, event_sequence),
               unique(session_handle, event_id)
             );
             create table if not exists host_committed_preparations (
               preparation_id text primary key, consumed_token_digest text not null,
               lease_generation text not null, run_id text not null unique
             );
             create table if not exists host_run_snapshots (
               run_id text primary key, snapshot_digest text not null,
               snapshot_json text not null
             );
             create table if not exists host_agent_events (
               run_id text not null, sequence text not null, code text not null,
               payload text not null, primary key(run_id, sequence)
             );",
        )
        .map_err(sqlite_error)
}

fn migrate_sidecar_if_needed(
    connection: &mut Connection,
    main_path: &Path,
    failure: Option<RuntimeStateMigrationFailurePoint>,
) -> Result<(), RuntimeStateError> {
    let state: String = connection
        .query_row(
            "select migration_state from runtime_state_meta where singleton_id = 1",
            [],
            |row| row.get(0),
        )
        .map_err(sqlite_error)?;
    if MigrationState::from_str(&state)? == MigrationState::UnifiedV2Active {
        return Ok(());
    }
    let sidecar_path = PathBuf::from(format!("{}.agent-os", main_path.display()));
    if !sidecar_path.exists() {
        activate_without_sidecar(connection)?;
        return Ok(());
    }
    let source_digest = file_sha256(&sidecar_path)?;
    connection
        .execute(
            "attach database ?1 as agent_os_sidecar",
            params![sidecar_path.to_string_lossy().as_ref()],
        )
        .map_err(sqlite_error)?;
    let migration_result = (|| {
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(sqlite_error)?;
        validate_legacy_source(&transaction)?;
        copy_legacy_tables(&transaction)?;
        if failure == Some(RuntimeStateMigrationFailurePoint::AfterLegacyCopy) {
            return Err(RuntimeStateError::new(
                "runtime_state.migration_injected_failure",
                "injected migration failure after legacy copy",
            ));
        }
        transaction
            .execute(
                "update runtime_state_meta set schema_version = ?1, migration_state = ?2,
                   migration_source_digest = ?3 where singleton_id = 1",
                params![
                    RUNTIME_STATE_SCHEMA_VERSION,
                    MigrationState::UnifiedV2Active.as_str(),
                    source_digest
                ],
            )
            .map_err(sqlite_error)?;
        transaction.commit().map_err(sqlite_error)
    })();
    connection
        .execute_batch("detach database agent_os_sidecar")
        .map_err(sqlite_error)?;
    migration_result?;
    Ok(())
}

fn validate_legacy_source(transaction: &Transaction<'_>) -> Result<(), RuntimeStateError> {
    let schema_version: String = transaction
        .query_row(
            "select cast(schema_version as text) from agent_os_sidecar.agent_os_schema_meta
             where singleton_id = 1",
            [],
            |row| row.get(0),
        )
        .map_err(sqlite_error)?;
    if schema_version != "1" {
        return Err(RuntimeStateError::new(
            "runtime_state.legacy_schema_unsupported",
            format!("unsupported Agent OS sidecar schema: {schema_version}"),
        ));
    }

    let lease: Option<(
        String,
        Option<String>,
        Option<String>,
        String,
        String,
        String,
    )> = transaction
        .query_row(
            "select cast(lease_generation as text), owner_run_id, preparation_id,
                    binding_schema, host_process_epoch, state
             from agent_os_sidecar.global_run_lease where singleton_id = 1",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .optional()
        .map_err(sqlite_error)?;
    if let Some((generation, owner, preparation, schema, epoch, state)) = lease {
        let valid = generation.parse::<u64>().is_ok()
            && !epoch.is_empty()
            && matches!(schema.as_str(), "legacy_v1" | "host_slot_v2")
            && matches!(state.as_str(), "preparing" | "active" | "releasing")
            && match state.as_str() {
                "preparing" => preparation.is_some(),
                "active" | "releasing" => owner.is_some() || preparation.is_some(),
                _ => false,
            };
        if !valid {
            return Err(RuntimeStateError::new(
                "runtime_state.legacy_row_invalid",
                "Agent OS sidecar contains an invalid global lease",
            ));
        }
    }

    let preparations_exist: bool = transaction
        .query_row(
            "select exists(
               select 1 from agent_os_sidecar.sqlite_master
               where type = 'table' and name = 'run_preparations'
             )",
            [],
            |row| row.get(0),
        )
        .map_err(sqlite_error)?;
    if preparations_exist {
        let mut statement = transaction
            .prepare("select record_json from agent_os_sidecar.run_preparations")
            .map_err(sqlite_error)?;
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(sqlite_error)?;
        for row in rows {
            serde_json::from_str::<crate::llm_contracts::RunPreparationRecord>(
                &row.map_err(sqlite_error)?,
            )
            .map_err(|error| {
                RuntimeStateError::new(
                    "runtime_state.legacy_row_invalid",
                    format!("invalid persisted preparation: {error}"),
                )
            })?;
        }
    }
    Ok(())
}

fn activate_without_sidecar(connection: &Connection) -> Result<(), RuntimeStateError> {
    connection
        .execute(
            "update runtime_state_meta set schema_version = ?1, migration_state = ?2
             where singleton_id = 1",
            params![
                RUNTIME_STATE_SCHEMA_VERSION,
                MigrationState::UnifiedV2Active.as_str()
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn copy_legacy_tables(transaction: &Transaction<'_>) -> Result<(), RuntimeStateError> {
    for (table, columns) in [
        (
            "agent_os_schema_meta",
            "singleton_id, schema_version, last_lease_generation",
        ),
        (
            "global_run_lease",
            "singleton_id, lease_generation, owner_run_id, preparation_id, binding_schema, host_process_epoch, state, preparation_expiration",
        ),
        (
            "host_binding_operations",
            "operation_token, token_digest, operation_kind, idempotency_key, subject_id, agent_profile_id, agent_profile_revision, llm_slot_id, requirements_hash, state",
        ),
        (
            "host_binding_cross_links",
            "operation_token, token_digest, operation_kind, llm_slot_id, requirements_hash, binding_id, binding_revision, binding_hash, staging_receipt_digest, state",
        ),
        (
            "run_preparations",
            "preparation_id, idempotency_key, proposed_run_id, token_generation, token_digest, binding_digest, source_revisions_digest, host_process_epoch, lease_generation, state, record_json",
        ),
        (
            "preparation_cleanup_outbox",
            "cleanup_command_id, preparation_id, cleanup_sequence, registration_digest, command_digest, state, record_json",
        ),
        (
            "preparation_cleanup_receipts",
            "cleanup_command_id, preparation_id, receipt_digest, close_disposition, record_json",
        ),
    ] {
        let exists: bool = transaction
            .query_row(
                "select exists(
                   select 1 from agent_os_sidecar.sqlite_master where type = 'table' and name = ?1
                 )",
                params![table],
                |row| row.get(0),
            )
            .map_err(sqlite_error)?;
        if !exists {
            continue;
        }
        transaction
            .execute(
                &format!(
                    "insert or replace into {table} ({columns}) select {columns} from agent_os_sidecar.{table}"
                ),
                [],
            )
            .map_err(sqlite_error)?;
    }
    Ok(())
}

fn file_sha256(path: &Path) -> Result<String, RuntimeStateError> {
    let bytes = fs::read(path).map_err(|error| {
        RuntimeStateError::new(
            "runtime_state.migration_source_unreadable",
            error.to_string(),
        )
    })?;
    let digest = Sha256::digest(bytes);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn insert_worker(
    transaction: &Transaction<'_>,
    worker: &HostWorkerRecord,
) -> Result<(), RuntimeStateError> {
    transaction
        .execute(
            "insert into host_workers(
               run_id, session_handle, host_process_epoch, revision, execution_phase,
               logical_outcome, resource_lifecycle, expected_command_sequence,
               expected_event_sequence, record_json
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                worker.run_id(),
                worker.session_handle(),
                worker.host_process_epoch(),
                worker.revision().to_string(),
                worker
                    .execution_phase()
                    .map(|value| encode(&value))
                    .transpose()?,
                encode(worker.logical_outcome())?,
                encode(worker.resource_lifecycle())?,
                worker.expected_command_sequence().to_string(),
                worker.expected_event_sequence().to_string(),
                encode(worker)?
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn update_worker(
    transaction: &Transaction<'_>,
    expected_revision: u64,
    worker: &HostWorkerRecord,
) -> Result<(), RuntimeStateError> {
    let changed = transaction
        .execute(
            "update host_workers set revision = ?1, execution_phase = ?2,
               logical_outcome = ?3, resource_lifecycle = ?4,
               expected_command_sequence = ?5, expected_event_sequence = ?6,
               record_json = ?7
             where run_id = ?8 and revision = ?9 and session_handle = ?10
               and host_process_epoch = ?11",
            params![
                worker.revision().to_string(),
                worker
                    .execution_phase()
                    .map(|value| encode(&value))
                    .transpose()?,
                encode(worker.logical_outcome())?,
                encode(worker.resource_lifecycle())?,
                worker.expected_command_sequence().to_string(),
                worker.expected_event_sequence().to_string(),
                encode(worker)?,
                worker.run_id(),
                expected_revision.to_string(),
                worker.session_handle(),
                worker.host_process_epoch()
            ],
        )
        .map_err(sqlite_error)?;
    if changed == 1 {
        Ok(())
    } else {
        Err(RuntimeStateError::new(
            "runtime_state.worker_cas_conflict",
            "worker revision or identity changed",
        ))
    }
}

fn load_worker(
    connection: &Connection,
    run_id: &str,
) -> Result<Option<HostWorkerRecord>, RuntimeStateError> {
    connection
        .query_row(
            "select record_json from host_workers where run_id = ?1",
            params![run_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(sqlite_error)?
        .map(|json| decode(&json))
        .transpose()
}

fn insert_session(
    transaction: &Transaction<'_>,
    session: &HostSessionRecord,
) -> Result<(), RuntimeStateError> {
    transaction
        .execute(
            "insert into host_sessions(
               session_handle, run_id, host_process_epoch, binding_id,
               binding_revision, binding_hash, resource_lifecycle, record_json
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                session.session_handle(),
                session.run_id(),
                session.host_process_epoch(),
                session.binding_id(),
                session.binding_revision().to_string(),
                session.binding_hash(),
                encode(session.resource_lifecycle())?,
                encode(session)?
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn load_session(
    connection: &Connection,
    session_handle: &str,
) -> Result<Option<HostSessionRecord>, RuntimeStateError> {
    connection
        .query_row(
            "select record_json from host_sessions where session_handle = ?1",
            params![session_handle],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(sqlite_error)?
        .map(|json| decode(&json))
        .transpose()
}

fn update_session(
    transaction: &Transaction<'_>,
    session: &HostSessionRecord,
) -> Result<(), RuntimeStateError> {
    let changed = transaction
        .execute(
            "update host_sessions set resource_lifecycle = ?1, record_json = ?2
             where session_handle = ?3 and run_id = ?4 and host_process_epoch = ?5",
            params![
                encode(session.resource_lifecycle())?,
                encode(session)?,
                session.session_handle(),
                session.run_id(),
                session.host_process_epoch()
            ],
        )
        .map_err(sqlite_error)?;
    if changed == 1 {
        Ok(())
    } else {
        Err(conflict())
    }
}

fn insert_outbox(
    transaction: &Transaction<'_>,
    row: &HostCommandOutboxRow,
) -> Result<(), RuntimeStateError> {
    transaction
        .execute(
            "insert into host_command_outbox(
               command_id, run_id, session_handle, host_process_epoch, command_sequence,
               command_envelope_digest, status, payload_json, record_json
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                row.command_id(),
                row.run_id(),
                row.session_handle(),
                row.host_process_epoch(),
                row.command_sequence().to_string(),
                row.command_envelope_digest(),
                encode(&row.status())?.trim_matches('"'),
                row.payload().map(encode).transpose()?,
                encode(row)?
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn update_outbox(
    transaction: &Transaction<'_>,
    row: &HostCommandOutboxRow,
) -> Result<(), RuntimeStateError> {
    let status = encode(&row.status())?;
    let changed = transaction
        .execute(
            "update host_command_outbox set status = ?1, payload_json = ?2, record_json = ?3
             where command_id = ?4 and session_handle = ?5 and command_sequence = ?6
               and command_envelope_digest = ?7",
            params![
                status.trim_matches('"'),
                row.payload().map(encode).transpose()?,
                encode(row)?,
                row.command_id(),
                row.session_handle(),
                row.command_sequence().to_string(),
                row.command_envelope_digest()
            ],
        )
        .map_err(sqlite_error)?;
    if changed == 1 {
        Ok(())
    } else {
        Err(conflict())
    }
}

fn load_outbox(
    connection: &Connection,
    command_id: &str,
) -> Result<Option<HostCommandOutboxRow>, RuntimeStateError> {
    connection
        .query_row(
            "select record_json from host_command_outbox where command_id = ?1",
            params![command_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(sqlite_error)?
        .map(|json| decode(&json))
        .transpose()
}

fn insert_event_receipt(
    transaction: &Transaction<'_>,
    receipt: &LLMEventReceipt,
) -> Result<(), RuntimeStateError> {
    let value = serde_json::to_value(receipt).map_err(contract_error)?;
    transaction
        .execute(
            "insert into llm_event_receipts(
               session_handle, event_sequence, event_id, event_envelope_digest,
               disposition, receipt_digest, record_json
             ) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                value["session_handle"].as_str(),
                value["event_sequence"]
                    .as_u64()
                    .map(|value| value.to_string()),
                value["event_id"].as_str(),
                receipt.event_envelope_digest(),
                value["disposition"].as_str(),
                receipt.receipt_digest(),
                encode(receipt)?
            ],
        )
        .map_err(sqlite_error)?;
    Ok(())
}

fn encode<T: serde::Serialize + ?Sized>(value: &T) -> Result<String, RuntimeStateError> {
    serde_json::to_string(value).map_err(contract_error)
}

fn decode<T: serde::de::DeserializeOwned>(value: &str) -> Result<T, RuntimeStateError> {
    serde_json::from_str(value).map_err(contract_error)
}

fn sqlite_error(error: rusqlite::Error) -> RuntimeStateError {
    if error.sqlite_error_code() == Some(rusqlite::ErrorCode::ConstraintViolation) {
        conflict()
    } else {
        RuntimeStateError::new("runtime_state.sqlite", error.to_string())
    }
}

fn agent_os_error(error: crate::llm_contracts::HostBindingError) -> RuntimeStateError {
    RuntimeStateError::new("runtime_state.agent_os_sqlite", error.to_string())
}
