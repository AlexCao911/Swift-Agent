use std::collections::BTreeMap;
use std::fmt;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::execution::{ExecutionEvent, ExecutionEventRepository};
use crate::llm_contracts::{
    HostCommandAcknowledgement, HostCommandAcknowledgementDisposition, HostCommandCopyReceipt,
    HostCommandEnvelope, HostRunHandle, HostSessionCloseDisposition, HostSessionRecord,
    HostWorkerRecord, LLMEventEnvelope, LLMEventReceipt, LLMEventReceiptDisposition,
    LLMEventSubmissionResult, LogicalRunOutcome, PreparationError, PreparationReconciliation,
    PreparedSessionCleanupIdentity, ResourceLifecycle, RunPreparationState,
};
use crate::storage::agent_os_state::{PreparedRunConsumption, SharedAgentOSStateStore};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeAggregateFailurePoint {
    AfterPreparationCommit,
    AfterSnapshotWrite,
    AfterAgentEventWrite,
    AfterWorkerWrite,
    AfterSessionWrite,
    AfterOutboxWrite,
}

impl RuntimeAggregateFailurePoint {
    pub const fn phase_c_points() -> [Self; 6] {
        [
            Self::AfterPreparationCommit,
            Self::AfterSnapshotWrite,
            Self::AfterAgentEventWrite,
            Self::AfterWorkerWrite,
            Self::AfterSessionWrite,
            Self::AfterOutboxWrite,
        ]
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostCommandOutboxStatus {
    PendingCopy,
    Copied,
    Accepted,
    Rejected,
    Cancelled,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostCommandOutboxRow {
    command_id: String,
    run_id: String,
    session_handle: String,
    host_process_epoch: String,
    command_sequence: u64,
    command_envelope_digest: String,
    status: HostCommandOutboxStatus,
    #[serde(default)]
    copy_receipt: Option<HostCommandCopyReceipt>,
    #[serde(default)]
    acknowledgement: Option<HostCommandAcknowledgement>,
    #[serde(default)]
    payload: Option<HostCommandEnvelope>,
}

impl HostCommandOutboxRow {
    pub fn pending(command: HostCommandEnvelope) -> Self {
        Self {
            command_id: command.command_id().to_string(),
            run_id: command.run_id().to_string(),
            session_handle: command.session_handle().to_string(),
            host_process_epoch: command.host_process_epoch().to_string(),
            command_sequence: command.command_sequence(),
            command_envelope_digest: command.command_envelope_digest().to_string(),
            status: HostCommandOutboxStatus::PendingCopy,
            copy_receipt: None,
            acknowledgement: None,
            payload: Some(command),
        }
    }

    pub fn command_id(&self) -> &str {
        &self.command_id
    }
    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn command_sequence(&self) -> u64 {
        self.command_sequence
    }
    pub fn command_envelope_digest(&self) -> &str {
        &self.command_envelope_digest
    }
    pub fn status(&self) -> HostCommandOutboxStatus {
        self.status
    }
    pub fn payload(&self) -> Option<&HostCommandEnvelope> {
        self.payload.as_ref()
    }
    pub fn copy_receipt(&self) -> Option<HostCommandCopyReceipt> {
        self.copy_receipt
    }
    pub(crate) fn with_copy_receipt(mut self, receipt: HostCommandCopyReceipt) -> Self {
        self.copy_receipt = Some(receipt);
        self.status = if receipt == HostCommandCopyReceipt::Copied {
            HostCommandOutboxStatus::Copied
        } else {
            HostCommandOutboxStatus::PendingCopy
        };
        self
    }
    pub(crate) fn with_acknowledgement(
        mut self,
        acknowledgement: HostCommandAcknowledgement,
    ) -> Self {
        self.status = match acknowledgement.disposition() {
            HostCommandAcknowledgementDisposition::Accepted => HostCommandOutboxStatus::Accepted,
            HostCommandAcknowledgementDisposition::Rejected => HostCommandOutboxStatus::Rejected,
        };
        if acknowledgement.disposition() == HostCommandAcknowledgementDisposition::Accepted {
            self.payload = None;
        }
        self.acknowledgement = Some(acknowledgement);
        self
    }
    pub(crate) fn cancelled(mut self) -> Self {
        self.status = HostCommandOutboxStatus::Cancelled;
        self.payload = None;
        self
    }
}

#[derive(Clone, Debug)]
pub struct RuntimeTransition {
    expected_worker_revision: u64,
    next_worker: HostWorkerRecord,
    command: HostCommandEnvelope,
}

impl RuntimeTransition {
    pub fn new(
        expected_worker_revision: u64,
        next_worker: HostWorkerRecord,
        command: HostCommandEnvelope,
    ) -> Self {
        Self {
            expected_worker_revision,
            next_worker,
            command,
        }
    }
    pub fn expected_worker_revision(&self) -> u64 {
        self.expected_worker_revision
    }
    pub fn next_worker(&self) -> &HostWorkerRecord {
        &self.next_worker
    }
    pub fn command(&self) -> &HostCommandEnvelope {
        &self.command
    }
}

#[derive(Clone, Debug)]
pub struct PreparedHostRunCommit {
    pub preparation_id: String,
    pub consumed_token_digest: String,
    pub lease_generation: u64,
    pub snapshot_digest: String,
    pub snapshot_json: String,
    pub initial_event_code: String,
    pub initial_event_payload: String,
    pub worker: HostWorkerRecord,
    pub session: HostSessionRecord,
    pub first_command: HostCommandEnvelope,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct RuntimeAggregateInspection {
    pub committed_preparation: bool,
    pub snapshot: bool,
    pub agent_event: bool,
    pub worker: bool,
    pub session: bool,
    pub outbox: bool,
}

impl RuntimeAggregateInspection {
    pub const EMPTY: Self = Self {
        committed_preparation: false,
        snapshot: false,
        agent_event: false,
        worker: false,
        session: false,
        outbox: false,
    };
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeStateError {
    code: &'static str,
    message: String,
}

impl RuntimeStateError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub fn code(&self) -> &str {
        self.code
    }
}

impl fmt::Display for RuntimeStateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RuntimeStateError {}

pub trait UnifiedRuntimeStateRepository: Send + Sync + 'static {
    fn insert_worker_and_session(
        &self,
        worker: HostWorkerRecord,
        session: HostSessionRecord,
    ) -> Result<(), RuntimeStateError>;
    fn commit_prepared_host_run(
        &self,
        commit: PreparedHostRunCommit,
    ) -> Result<(), RuntimeStateError>;
    fn transition_and_enqueue(
        &self,
        transition: RuntimeTransition,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError>;
    fn record_copy_receipt(
        &self,
        command_id: &str,
        receipt: HostCommandCopyReceipt,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError>;
    fn acknowledge_command(
        &self,
        acknowledgement: &HostCommandAcknowledgement,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError>;
    fn apply_event_transactionally(
        &self,
        event: &LLMEventEnvelope,
        result: LLMEventSubmissionResult,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError>;
    fn begin_terminal_close(
        &self,
        transition: RuntimeTransition,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        self.transition_and_enqueue(transition)
    }
    fn recover_run_for_epoch(
        &self,
        run_id: &str,
        current_epoch: &str,
    ) -> Result<HostWorkerRecord, RuntimeStateError>;
    fn host_worker(&self, run_id: &str) -> Result<Option<HostWorkerRecord>, RuntimeStateError>;
    fn host_session(
        &self,
        session_handle: &str,
    ) -> Result<Option<HostSessionRecord>, RuntimeStateError>;
    fn run_snapshot_json(&self, run_id: &str) -> Result<Option<String>, RuntimeStateError>;
    fn committed_run_handle(
        &self,
        preparation_id: &str,
        token_digest: &str,
    ) -> Result<Option<HostRunHandle>, RuntimeStateError>;
    fn reconcile_preparation(
        &self,
        preparation_id: &str,
        proposed_run_id: &str,
        token_digest: &str,
    ) -> Result<PreparationReconciliation, RuntimeStateError>;
    fn host_command(
        &self,
        command_id: &str,
    ) -> Result<Option<HostCommandOutboxRow>, RuntimeStateError>;
    fn pending_host_commands(&self) -> Result<Vec<HostCommandOutboxRow>, RuntimeStateError>;
    fn event_receipt(
        &self,
        session_handle: &str,
        event_sequence: u64,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError>;
    fn inspect_v2_aggregate(
        &self,
        preparation_id: &str,
        run_id: &str,
        session_handle: &str,
    ) -> Result<RuntimeAggregateInspection, RuntimeStateError>;
}

#[derive(Clone)]
pub struct InMemoryRuntimeStateStore {
    inner: Arc<Mutex<InMemoryRuntimeState>>,
    failure: Arc<Mutex<Option<RuntimeAggregateFailurePoint>>>,
    agent_os_state: SharedAgentOSStateStore,
    execution_subscribers: Arc<Mutex<BTreeMap<String, Vec<Sender<ExecutionEvent>>>>>,
}

#[derive(Clone, Default)]
struct InMemoryRuntimeState {
    workers: BTreeMap<String, HostWorkerRecord>,
    sessions: BTreeMap<String, HostSessionRecord>,
    commands: BTreeMap<String, HostCommandOutboxRow>,
    event_receipts: BTreeMap<(String, u64), LLMEventReceipt>,
    committed_preparations: BTreeMap<String, (String, u64, String)>,
    snapshots: BTreeMap<String, (String, String)>,
    agent_events: BTreeMap<String, Vec<(String, String)>>,
}

impl InMemoryRuntimeStateStore {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(InMemoryRuntimeState::default())),
            failure: Arc::new(Mutex::new(None)),
            agent_os_state: SharedAgentOSStateStore::in_memory(),
            execution_subscribers: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }
    pub fn agent_os_state(&self) -> SharedAgentOSStateStore {
        self.agent_os_state.clone()
    }
    pub fn inject_failure(&self, point: RuntimeAggregateFailurePoint) {
        *self
            .failure
            .lock()
            .unwrap_or_else(|value| value.into_inner()) = Some(point);
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

impl Default for InMemoryRuntimeStateStore {
    fn default() -> Self {
        Self::new()
    }
}

impl UnifiedRuntimeStateRepository for InMemoryRuntimeStateStore {
    fn insert_worker_and_session(
        &self,
        worker: HostWorkerRecord,
        session: HostSessionRecord,
    ) -> Result<(), RuntimeStateError> {
        validate_worker_session(&worker, &session)?;
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        if state.workers.contains_key(worker.run_id())
            || state.sessions.contains_key(session.session_handle())
        {
            return Err(conflict());
        }
        state.workers.insert(worker.run_id().to_string(), worker);
        state
            .sessions
            .insert(session.session_handle().to_string(), session);
        Ok(())
    }

    fn commit_prepared_host_run(
        &self,
        commit: PreparedHostRunCommit,
    ) -> Result<(), RuntimeStateError> {
        validate_worker_session(&commit.worker, &commit.session)?;
        validate_command_for_worker(&commit.worker, &commit.first_command)?;
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let mut next = state.clone();
        let result = (|| {
            next.committed_preparations.insert(
                commit.preparation_id.clone(),
                (
                    commit.consumed_token_digest.clone(),
                    commit.lease_generation,
                    commit.worker.run_id().to_string(),
                ),
            );
            self.take_failure(RuntimeAggregateFailurePoint::AfterPreparationCommit)?;
            next.snapshots.insert(
                commit.worker.run_id().to_string(),
                (commit.snapshot_digest.clone(), commit.snapshot_json.clone()),
            );
            self.take_failure(RuntimeAggregateFailurePoint::AfterSnapshotWrite)?;
            next.agent_events
                .entry(commit.worker.run_id().to_string())
                .or_default()
                .push((
                    commit.initial_event_code.clone(),
                    commit.initial_event_payload.clone(),
                ));
            self.take_failure(RuntimeAggregateFailurePoint::AfterAgentEventWrite)?;
            next.workers
                .insert(commit.worker.run_id().to_string(), commit.worker.clone());
            self.take_failure(RuntimeAggregateFailurePoint::AfterWorkerWrite)?;
            next.sessions.insert(
                commit.session.session_handle().to_string(),
                commit.session.clone(),
            );
            self.take_failure(RuntimeAggregateFailurePoint::AfterSessionWrite)?;
            let row = HostCommandOutboxRow::pending(commit.first_command.clone());
            next.commands.insert(row.command_id().to_string(), row);
            self.take_failure(RuntimeAggregateFailurePoint::AfterOutboxWrite)?;
            Ok(())
        })();
        result?;

        let consumption = PreparedRunConsumption {
            preparation_id: commit.preparation_id,
            proposed_run_id: commit.worker.run_id().to_string(),
            token_digest: commit.consumed_token_digest,
            lease_generation: commit.lease_generation,
            session_handle: commit.session.session_handle().to_string(),
            host_process_epoch: commit.worker.host_process_epoch().to_string(),
            binding_id: commit.session.binding_id().to_string(),
            binding_revision: commit.session.binding_revision(),
            binding_hash: commit.session.binding_hash().to_string(),
        };
        self.agent_os_state
            .with_preparation_mut(|repository| {
                repository.consume_registered_preparation_and_promote(&consumption)?;
                *state = next;
                Ok(())
            })
            .map_err(preparation_commit_error)
    }

    fn transition_and_enqueue(
        &self,
        transition: RuntimeTransition,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let current = state
            .workers
            .get(transition.next_worker.run_id())
            .ok_or_else(not_found)?
            .clone();
        validate_transition(&current, &transition)?;
        let original = state.clone();
        state.workers.insert(
            current.run_id().to_string(),
            transition
                .next_worker
                .clone()
                .with_expected_command_sequence(current.expected_command_sequence() + 1),
        );
        if let Err(error) = self.take_failure(RuntimeAggregateFailurePoint::AfterWorkerWrite) {
            *state = original;
            return Err(error);
        }
        let row = HostCommandOutboxRow::pending(transition.command);
        if state.commands.contains_key(row.command_id())
            || state.commands.values().any(|existing| {
                existing.session_handle() == row.session_handle()
                    && existing.command_sequence() == row.command_sequence()
            })
        {
            *state = original;
            return Err(conflict());
        }
        state
            .commands
            .insert(row.command_id().to_string(), row.clone());
        if let Err(error) = self.take_failure(RuntimeAggregateFailurePoint::AfterOutboxWrite) {
            *state = original;
            return Err(error);
        }
        Ok(row)
    }

    fn record_copy_receipt(
        &self,
        command_id: &str,
        receipt: HostCommandCopyReceipt,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let row = state.commands.get_mut(command_id).ok_or_else(not_found)?;
        row.copy_receipt = Some(receipt);
        row.status = if receipt == HostCommandCopyReceipt::Copied {
            HostCommandOutboxStatus::Copied
        } else {
            HostCommandOutboxStatus::PendingCopy
        };
        Ok(row.clone())
    }

    fn acknowledge_command(
        &self,
        acknowledgement: &HostCommandAcknowledgement,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let row = state
            .commands
            .get_mut(acknowledgement.command_id())
            .ok_or_else(not_found)?;
        validate_ack(row, acknowledgement)?;
        row.status = match acknowledgement.disposition() {
            HostCommandAcknowledgementDisposition::Accepted => HostCommandOutboxStatus::Accepted,
            HostCommandAcknowledgementDisposition::Rejected => HostCommandOutboxStatus::Rejected,
        };
        if acknowledgement.disposition() == HostCommandAcknowledgementDisposition::Accepted {
            row.payload = None;
        }
        row.acknowledgement = Some(acknowledgement.clone());
        Ok(row.clone())
    }

    fn apply_event_transactionally(
        &self,
        event: &LLMEventEnvelope,
        result: LLMEventSubmissionResult,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
        apply_event_in_memory(&self.inner, event, result)
    }

    fn recover_run_for_epoch(
        &self,
        run_id: &str,
        current_epoch: &str,
    ) -> Result<HostWorkerRecord, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let worker = state.workers.get(run_id).ok_or_else(not_found)?.clone();
        if worker.host_process_epoch() == current_epoch {
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
        state.workers.insert(run_id.to_string(), recovered.clone());
        if let Some(session) = state.sessions.get_mut(worker.session_handle()) {
            *session = session
                .clone()
                .with_resource_lifecycle(ResourceLifecycle::Closed {
                    disposition: HostSessionCloseDisposition::EpochEnded,
                });
        }
        state
            .agent_events
            .entry(run_id.to_string())
            .or_default()
            .push(("run.interrupted".into(), "host_epoch_ended".into()));
        for row in state
            .commands
            .values_mut()
            .filter(|row| row.run_id() == run_id)
        {
            *row = row.clone().cancelled();
        }
        Ok(recovered)
    }

    fn host_worker(&self, run_id: &str) -> Result<Option<HostWorkerRecord>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .workers
            .get(run_id)
            .cloned())
    }

    fn host_session(
        &self,
        session_handle: &str,
    ) -> Result<Option<HostSessionRecord>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .sessions
            .get(session_handle)
            .cloned())
    }

    fn run_snapshot_json(&self, run_id: &str) -> Result<Option<String>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .snapshots
            .get(run_id)
            .map(|(_, json)| json.clone()))
    }

    fn committed_run_handle(
        &self,
        preparation_id: &str,
        token_digest: &str,
    ) -> Result<Option<HostRunHandle>, RuntimeStateError> {
        let state = self.inner.lock().map_err(|_| poisoned())?;
        let Some((consumed_digest, _, run_id)) = state.committed_preparations.get(preparation_id)
        else {
            return Ok(None);
        };
        if consumed_digest != token_digest {
            return Err(reconciliation_conflict());
        }
        let command = state
            .commands
            .values()
            .find(|row| row.run_id() == run_id && row.command_sequence() == 1)
            .ok_or_else(not_found)?;
        Ok(Some(HostRunHandle::new(
            run_id,
            command.session_handle(),
            command.command_id(),
        )))
    }

    fn reconcile_preparation(
        &self,
        preparation_id: &str,
        proposed_run_id: &str,
        token_digest: &str,
    ) -> Result<PreparationReconciliation, RuntimeStateError> {
        let committed = {
            let state = self.inner.lock().map_err(|_| poisoned())?;
            state
                .committed_preparations
                .get(preparation_id)
                .cloned()
                .map(|(consumed_digest, _, run_id)| {
                    let command = state
                        .commands
                        .values()
                        .find(|row| row.run_id() == run_id && row.command_sequence() == 1)
                        .cloned();
                    (consumed_digest, run_id, command)
                })
        };
        if let Some((consumed_digest, run_id, command)) = committed {
            if run_id != proposed_run_id || consumed_digest != token_digest {
                return Err(reconciliation_conflict());
            }
            let command = command.ok_or_else(not_found)?;
            return Ok(PreparationReconciliation::Committed {
                handle: HostRunHandle::new(run_id, command.session_handle(), command.command_id()),
            });
        }

        let record = self
            .agent_os_state
            .with_preparation(|repository| repository.run_preparation(preparation_id))
            .map_err(preparation_commit_error)?
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
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .commands
            .get(command_id)
            .cloned())
    }

    fn pending_host_commands(&self) -> Result<Vec<HostCommandOutboxRow>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .commands
            .values()
            .filter(|row| {
                matches!(
                    row.status(),
                    HostCommandOutboxStatus::PendingCopy | HostCommandOutboxStatus::Copied
                )
            })
            .cloned()
            .collect())
    }

    fn event_receipt(
        &self,
        session_handle: &str,
        event_sequence: u64,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .event_receipts
            .get(&(session_handle.to_string(), event_sequence))
            .cloned())
    }

    fn inspect_v2_aggregate(
        &self,
        preparation_id: &str,
        run_id: &str,
        session_handle: &str,
    ) -> Result<RuntimeAggregateInspection, RuntimeStateError> {
        let state = self.inner.lock().map_err(|_| poisoned())?;
        Ok(RuntimeAggregateInspection {
            committed_preparation: state.committed_preparations.contains_key(preparation_id),
            snapshot: state.snapshots.contains_key(run_id),
            agent_event: state.agent_events.contains_key(run_id),
            worker: state.workers.contains_key(run_id),
            session: state.sessions.contains_key(session_handle),
            outbox: state.commands.values().any(|row| row.run_id() == run_id),
        })
    }
}

impl ExecutionEventRepository for InMemoryRuntimeStateStore {
    fn append(&self, run_id: String, code: String, payload: String) -> ExecutionEvent {
        let event = {
            let mut state = self
                .inner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let events = state.agent_events.entry(run_id.clone()).or_default();
            let sequence = events.len() as u64 + 1;
            events.push((code.clone(), payload.clone()));
            ExecutionEvent::persisted(run_id.clone(), sequence, code, payload)
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
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .agent_events
            .get(run_id)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .filter_map(|(index, (code, payload))| {
                let sequence = index as u64 + 1;
                (sequence > from_sequence)
                    .then(|| ExecutionEvent::persisted(run_id, sequence, code, payload))
            })
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

fn apply_event_in_memory(
    state: &Mutex<InMemoryRuntimeState>,
    event: &LLMEventEnvelope,
    result: LLMEventSubmissionResult,
) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
    let mut state = state.lock().map_err(|_| poisoned())?;
    if result == LLMEventSubmissionResult::Duplicate {
        return Ok(state
            .event_receipts
            .get(&(event.session_handle().to_string(), event.event_sequence()))
            .cloned());
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
    let worker = state
        .workers
        .get(event.run_id())
        .ok_or_else(not_found)?
        .clone();
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
    state.event_receipts.insert(
        (event.session_handle().to_string(), event.event_sequence()),
        receipt.clone(),
    );
    state.workers.insert(
        worker.run_id().to_string(),
        worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_expected_event_sequence(worker.expected_event_sequence() + 1),
    );
    Ok(Some(receipt))
}

pub(crate) fn validate_worker_session(
    worker: &HostWorkerRecord,
    session: &HostSessionRecord,
) -> Result<(), RuntimeStateError> {
    if worker.run_id() == session.run_id()
        && worker.session_handle() == session.session_handle()
        && worker.host_process_epoch() == session.host_process_epoch()
    {
        Ok(())
    } else {
        Err(RuntimeStateError::new(
            "runtime_state.identity_conflict",
            "worker and session identities differ",
        ))
    }
}

pub(crate) fn validate_command_for_worker(
    worker: &HostWorkerRecord,
    command: &HostCommandEnvelope,
) -> Result<(), RuntimeStateError> {
    if command.expected_digest().map_err(contract_error)? != command.command_envelope_digest() {
        return Err(RuntimeStateError::new(
            "llm.command.invalid_envelope",
            "command envelope digest mismatch",
        ));
    }
    if worker.run_id() == command.run_id()
        && worker.session_handle() == command.session_handle()
        && worker.host_process_epoch() == command.host_process_epoch()
        && worker.expected_command_sequence() == command.command_sequence()
    {
        Ok(())
    } else {
        Err(RuntimeStateError::new(
            "llm.command.identity_or_sequence_conflict",
            "command does not match worker identity and expected sequence",
        ))
    }
}

pub(crate) fn validate_transition(
    current: &HostWorkerRecord,
    transition: &RuntimeTransition,
) -> Result<(), RuntimeStateError> {
    validate_command_for_worker(current, transition.command())?;
    if current.revision() != transition.expected_worker_revision()
        || transition.next_worker().revision() != current.revision() + 1
        || transition.next_worker().run_id() != current.run_id()
        || transition.next_worker().session_handle() != current.session_handle()
        || transition.next_worker().host_process_epoch() != current.host_process_epoch()
    {
        return Err(RuntimeStateError::new(
            "runtime_state.worker_cas_conflict",
            "worker transition did not match the expected revision and identity",
        ));
    }
    Ok(())
}

pub(crate) fn validate_ack(
    row: &HostCommandOutboxRow,
    acknowledgement: &HostCommandAcknowledgement,
) -> Result<(), RuntimeStateError> {
    if row.command_id() == acknowledgement.command_id()
        && row.session_handle() == acknowledgement.session_handle()
        && row.command_sequence() == acknowledgement.command_sequence()
        && row.command_envelope_digest() == acknowledgement.command_envelope_digest()
    {
        Ok(())
    } else {
        Err(RuntimeStateError::new(
            "llm.command.ack_identity_conflict",
            "command acknowledgement does not match the durable outbox row",
        ))
    }
}

pub(crate) fn contract_error(error: impl fmt::Display) -> RuntimeStateError {
    RuntimeStateError::new("runtime_state.contract_invalid", error.to_string())
}

fn preparation_commit_error(error: PreparationError) -> RuntimeStateError {
    RuntimeStateError::new(
        "runtime_state.preparation_cas_conflict",
        format!("{}: {error}", error.code()),
    )
}

pub(crate) fn transaction_failed() -> RuntimeStateError {
    RuntimeStateError::new(
        "llm.command.transaction_failed",
        "runtime aggregate transaction failed",
    )
}

pub(crate) fn conflict() -> RuntimeStateError {
    RuntimeStateError::new(
        "runtime_state.conflict",
        "runtime aggregate identity conflict",
    )
}

pub(crate) fn not_found() -> RuntimeStateError {
    RuntimeStateError::new(
        "runtime_state.not_found",
        "runtime aggregate record was not found",
    )
}

pub(crate) fn reconciliation_conflict() -> RuntimeStateError {
    RuntimeStateError::new(
        "preparation.reconciliation_identity_mismatch",
        "preparation reconciliation identity or consumed token digest does not match",
    )
}

pub(crate) fn poisoned() -> RuntimeStateError {
    RuntimeStateError::new("runtime_state.poisoned", "runtime state mutex is poisoned")
}
