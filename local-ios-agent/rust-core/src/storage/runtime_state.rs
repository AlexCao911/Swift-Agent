use std::collections::BTreeMap;
use std::fmt;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::execution::{ExecutionEvent, ExecutionEventRepository};
use crate::llm_contracts::{
    GlobalRunLeaseState, HostCommandAcknowledgement, HostCommandAcknowledgementDisposition,
    HostCommandCopyReceipt, HostCommandEnvelope, HostCommandKind, HostExecutionPhase,
    HostRunHandle, HostSessionCloseDisposition, HostSessionRecord, HostWatchdogKind,
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
    AfterEventReceiptWrite,
    AfterExpectedSequenceWrite,
    AfterInboundEventWrite,
    AfterEventAccumulatorWrite,
    AfterEventStateWrite,
    AfterEventAgentWrite,
    AfterEventOutboxWrite,
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

    pub const fn event_points() -> [Self; 6] {
        [
            Self::AfterEventReceiptWrite,
            Self::AfterExpectedSequenceWrite,
            Self::AfterInboundEventWrite,
            Self::AfterEventAccumulatorWrite,
            Self::AfterEventStateWrite,
            Self::AfterEventAgentWrite,
        ]
    }
}

pub const HOST_EVENT_MAX_EVENTS: usize = 256;
pub const HOST_EVENT_MAX_BYTES: usize = 2 * 1024 * 1024;
pub const HOST_EVENT_LOW_WATER_EVENTS: usize = 128;
pub const HOST_EVENT_LOW_WATER_BYTES: usize = 1024 * 1024;
pub const HOST_LIFECYCLE_TIMEOUT_MILLIS: u64 = 10_000;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct EventQueueUsage {
    pub event_count: usize,
    pub byte_count: usize,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostCommandOutboxStatus {
    PendingCopy,
    Copied,
    Accepted,
    Rejected,
    Cancelled,
    TimedOut,
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
    #[serde(default)]
    first_dispatch_millis: Option<u64>,
    #[serde(default)]
    next_dispatch_millis: Option<u64>,
    #[serde(default)]
    acknowledgement_deadline_millis: Option<u64>,
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
            first_dispatch_millis: None,
            next_dispatch_millis: None,
            acknowledgement_deadline_millis: None,
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
    pub fn acknowledgement(&self) -> Option<&HostCommandAcknowledgement> {
        self.acknowledgement.as_ref()
    }
    pub fn first_dispatch_millis(&self) -> Option<u64> {
        self.first_dispatch_millis
    }
    pub fn next_dispatch_millis(&self) -> Option<u64> {
        self.next_dispatch_millis
    }
    pub fn acknowledgement_deadline_millis(&self) -> Option<u64> {
        self.acknowledgement_deadline_millis
    }
    pub fn is_dispatch_due(&self, now_millis: u64) -> bool {
        self.next_dispatch_millis
            .map(|deadline| now_millis >= deadline)
            .unwrap_or(true)
    }
    pub fn is_acknowledgement_overdue(&self, now_millis: u64) -> bool {
        self.acknowledgement_deadline_millis
            .map(|deadline| now_millis >= deadline)
            .unwrap_or(false)
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
    pub(crate) fn with_timed_copy_receipt(
        mut self,
        receipt: HostCommandCopyReceipt,
        now_millis: u64,
        acknowledgement_timeout: Duration,
        redispatch_interval: Duration,
    ) -> Self {
        self = self.with_copy_receipt(receipt);
        self.first_dispatch_millis.get_or_insert(now_millis);
        self.acknowledgement_deadline_millis.get_or_insert_with(|| {
            now_millis.saturating_add(duration_millis(acknowledgement_timeout))
        });
        self.next_dispatch_millis =
            Some(now_millis.saturating_add(duration_millis(redispatch_interval).max(1)));
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
        self.payload = None;
        self.acknowledgement = Some(acknowledgement);
        self
    }
    pub(crate) fn cancelled(mut self) -> Self {
        self.status = HostCommandOutboxStatus::Cancelled;
        self.payload = None;
        self
    }
    pub(crate) fn timed_out(mut self) -> Self {
        self.status = HostCommandOutboxStatus::TimedOut;
        self.payload = None;
        self
    }
}

fn duration_millis(duration: Duration) -> u64 {
    duration.as_millis().try_into().unwrap_or(u64::MAX)
}

pub(crate) fn close_command_for(
    row: &HostCommandOutboxRow,
    worker: &HostWorkerRecord,
) -> Result<HostCommandEnvelope, RuntimeStateError> {
    let command_id = crate::llm_contracts::BearerTokenIssuer::system()
        .issue("saga-token:v1")
        .map_err(|error| RuntimeStateError::new("llm.command.id_failed", error.to_string()))?
        .raw()
        .to_string();
    HostCommandEnvelope::lifecycle(
        command_id,
        row.run_id(),
        row.session_handle(),
        row.host_process_epoch(),
        worker.expected_command_sequence(),
        HostCommandKind::CloseSession,
    )
    .map_err(|error| RuntimeStateError::new("llm.command.close_invalid", error.to_string()))
}

pub(crate) fn apply_command_acknowledgement_state(
    row: &HostCommandOutboxRow,
    acknowledgement: &HostCommandAcknowledgement,
    worker: &HostWorkerRecord,
    session: &HostSessionRecord,
) -> Result<
    (
        HostWorkerRecord,
        HostSessionRecord,
        Option<HostCommandEnvelope>,
    ),
    RuntimeStateError,
> {
    let kind = row
        .payload()
        .map(HostCommandEnvelope::kind)
        .ok_or_else(conflict)?;
    let mut next_worker = worker.clone().with_revision(worker.revision() + 1);
    let mut lifecycle = worker.resource_lifecycle().clone();
    let mut close_command = None;

    match acknowledgement.disposition() {
        HostCommandAcknowledgementDisposition::Accepted => match kind {
            HostCommandKind::StartGeneration | HostCommandKind::ResumeGeneration => {
                next_worker = next_worker
                    .with_execution_phase(Some(HostExecutionPhase::AwaitingGenerationStarted))
                    .with_watchdog(
                        Some(HostWatchdogKind::GenerationStart),
                        Some(acknowledgement.command_id().to_string()),
                        Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
                    );
            }
            HostCommandKind::CancelGeneration => {
                lifecycle = ResourceLifecycle::AwaitingCancelledTerminal;
                next_worker = next_worker.with_watchdog(
                    Some(HostWatchdogKind::CancelTerminal),
                    Some(acknowledgement.command_id().to_string()),
                    Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
                );
            }
            HostCommandKind::CloseSession => {
                lifecycle = ResourceLifecycle::AwaitingSessionClosed;
                next_worker = next_worker.with_watchdog(
                    Some(HostWatchdogKind::SessionClose),
                    Some(acknowledgement.command_id().to_string()),
                    Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
                );
            }
            HostCommandKind::CapacityAvailable => {}
        },
        HostCommandAcknowledgementDisposition::Rejected => {
            let code = acknowledgement
                .rejection_code()
                .unwrap_or("llm.command.rejected")
                .to_string();
            next_worker = next_worker
                .with_execution_phase(None)
                .with_watchdog(None, None, None);
            if matches!(worker.logical_outcome(), LogicalRunOutcome::Pending) {
                next_worker = next_worker
                    .with_logical_outcome(LogicalRunOutcome::Failed { code: code.clone() });
            }
            match kind {
                HostCommandKind::CloseSession | HostCommandKind::CapacityAvailable => {
                    lifecycle = ResourceLifecycle::Quarantined { code };
                }
                HostCommandKind::StartGeneration
                | HostCommandKind::ResumeGeneration
                | HostCommandKind::CancelGeneration => {
                    lifecycle = ResourceLifecycle::AwaitingCloseCommandAck;
                    close_command = Some(close_command_for(row, worker)?);
                    next_worker = next_worker
                        .with_expected_command_sequence(worker.expected_command_sequence() + 1);
                }
            }
        }
    }
    next_worker = next_worker.with_resource_lifecycle(lifecycle.clone());
    Ok((
        next_worker,
        session.clone().with_resource_lifecycle(lifecycle),
        close_command,
    ))
}

pub fn runtime_now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
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
    fn update_host_worker(
        &self,
        expected_revision: u64,
        worker: HostWorkerRecord,
    ) -> Result<HostWorkerRecord, RuntimeStateError>;
    fn record_copy_receipt(
        &self,
        command_id: &str,
        receipt: HostCommandCopyReceipt,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        self.record_copy_receipt_at(
            command_id,
            receipt,
            runtime_now_millis(),
            Duration::from_secs(10),
            Duration::from_millis(250),
        )
    }
    fn record_copy_receipt_at(
        &self,
        command_id: &str,
        receipt: HostCommandCopyReceipt,
        now_millis: u64,
        acknowledgement_timeout: Duration,
        redispatch_interval: Duration,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError>;
    fn fail_command_acknowledgement_timeout(
        &self,
        command_id: &str,
    ) -> Result<HostWorkerRecord, RuntimeStateError>;
    fn fail_expired_host_watchdogs(
        &self,
        now_millis: u64,
    ) -> Result<Vec<HostWorkerRecord>, RuntimeStateError>;
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
    fn event_receipt_by_id(
        &self,
        session_handle: &str,
        event_id: &str,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError>;
    fn event_queue_usage(&self, session_handle: &str)
        -> Result<EventQueueUsage, RuntimeStateError>;
    fn drain_inbound_events(
        &self,
        maximum: usize,
    ) -> Result<Vec<LLMEventEnvelope>, RuntimeStateError>;
    fn turn_accumulator_events(
        &self,
        session_handle: &str,
        generation_turn_id: &str,
    ) -> Result<Vec<LLMEventEnvelope>, RuntimeStateError>;
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
    inbound_events: BTreeMap<(String, u64), LLMEventEnvelope>,
    turn_accumulators: BTreeMap<(String, String), Vec<LLMEventEnvelope>>,
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
            next.workers.insert(
                commit.worker.run_id().to_string(),
                commit
                    .worker
                    .clone()
                    .with_expected_command_sequence(commit.first_command.command_sequence() + 1),
            );
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
        let worker = state
            .workers
            .get(row.run_id())
            .cloned()
            .ok_or_else(not_found)?;
        drop(state);
        sync_in_memory_global_lease(
            &self.agent_os_state,
            worker.run_id(),
            worker.host_process_epoch(),
            worker.resource_lifecycle(),
        )?;
        Ok(row)
    }

    fn update_host_worker(
        &self,
        expected_revision: u64,
        worker: HostWorkerRecord,
    ) -> Result<HostWorkerRecord, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let current = state.workers.get(worker.run_id()).ok_or_else(not_found)?;
        if current.revision() != expected_revision
            || worker.revision() != expected_revision + 1
            || current.session_handle() != worker.session_handle()
            || current.host_process_epoch() != worker.host_process_epoch()
        {
            return Err(conflict());
        }
        state
            .workers
            .insert(worker.run_id().to_string(), worker.clone());
        Ok(worker)
    }

    fn record_copy_receipt_at(
        &self,
        command_id: &str,
        receipt: HostCommandCopyReceipt,
        now_millis: u64,
        acknowledgement_timeout: Duration,
        redispatch_interval: Duration,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let row = state.commands.get_mut(command_id).ok_or_else(not_found)?;
        if !matches!(
            row.status(),
            HostCommandOutboxStatus::PendingCopy | HostCommandOutboxStatus::Copied
        ) {
            return Ok(row.clone());
        }
        *row = row.clone().with_timed_copy_receipt(
            receipt,
            now_millis,
            acknowledgement_timeout,
            redispatch_interval,
        );
        Ok(row.clone())
    }

    fn fail_command_acknowledgement_timeout(
        &self,
        command_id: &str,
    ) -> Result<HostWorkerRecord, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let row = state
            .commands
            .get(command_id)
            .ok_or_else(not_found)?
            .clone();
        if row.status() == HostCommandOutboxStatus::TimedOut {
            return state
                .workers
                .get(row.run_id())
                .cloned()
                .ok_or_else(not_found);
        }
        if !matches!(
            row.status(),
            HostCommandOutboxStatus::PendingCopy | HostCommandOutboxStatus::Copied
        ) {
            return Err(conflict());
        }
        let worker = state
            .workers
            .get(row.run_id())
            .ok_or_else(not_found)?
            .clone();
        let kind = row
            .payload()
            .map(HostCommandEnvelope::kind)
            .ok_or_else(conflict)?;
        let close_command = (!matches!(kind, HostCommandKind::CloseSession))
            .then(|| close_command_for(&row, &worker))
            .transpose()?;
        let lifecycle = if close_command.is_some() {
            ResourceLifecycle::AwaitingCloseCommandAck
        } else {
            ResourceLifecycle::Quarantined {
                code: "llm.command.ack_timeout".into(),
            }
        };
        let logical_outcome = if matches!(worker.logical_outcome(), LogicalRunOutcome::Pending) {
            LogicalRunOutcome::Failed {
                code: "llm.command.ack_timeout".into(),
            }
        } else {
            worker.logical_outcome().clone()
        };
        let mut failed = worker
            .clone()
            .with_revision(worker.revision() + 1)
            .with_execution_phase(None)
            .with_logical_outcome(logical_outcome)
            .with_resource_lifecycle(lifecycle.clone())
            .with_expected_command_sequence(
                worker.expected_command_sequence() + u64::from(close_command.is_some()),
            )
            .with_watchdog(None, None, None);
        if let Some(close) = close_command.as_ref() {
            failed = failed.with_watchdog(
                Some(HostWatchdogKind::CloseCommandAck),
                Some(close.command_id().to_string()),
                Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
            );
        }
        state
            .workers
            .insert(row.run_id().to_string(), failed.clone());
        if let Some(session) = state.sessions.get_mut(row.session_handle()) {
            *session = session.clone().with_resource_lifecycle(lifecycle);
        }
        state
            .commands
            .insert(command_id.to_string(), row.timed_out());
        if let Some(close_command) = close_command {
            let close_row = HostCommandOutboxRow::pending(close_command);
            state
                .commands
                .insert(close_row.command_id().to_string(), close_row);
        }
        Ok(failed)
    }

    fn fail_expired_host_watchdogs(
        &self,
        now_millis: u64,
    ) -> Result<Vec<HostWorkerRecord>, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let run_ids = state
            .workers
            .values()
            .filter(|worker| {
                worker
                    .watchdog_deadline_millis()
                    .is_some_and(|deadline| deadline <= now_millis)
            })
            .map(|worker| worker.run_id().to_string())
            .collect::<Vec<_>>();
        let mut expired = Vec::with_capacity(run_ids.len());
        for run_id in run_ids {
            let worker = state.workers.get(&run_id).cloned().ok_or_else(not_found)?;
            let session = state
                .sessions
                .get(worker.session_handle())
                .cloned()
                .ok_or_else(not_found)?;
            let Some((next_worker, next_session, close)) =
                expired_watchdog_state(&worker, &session, now_millis)?
            else {
                continue;
            };
            if let Some(command_id) = worker.watchdog_command_id() {
                if let Some(row) = state.commands.get_mut(command_id) {
                    *row = row.clone().timed_out();
                }
            }
            state
                .workers
                .insert(next_worker.run_id().to_string(), next_worker.clone());
            state
                .sessions
                .insert(next_session.session_handle().to_string(), next_session);
            if let Some(close) = close {
                state.commands.insert(
                    close.command_id().to_string(),
                    HostCommandOutboxRow::pending(close),
                );
            }
            expired.push(next_worker);
        }
        drop(state);
        for worker in &expired {
            sync_in_memory_global_lease(
                &self.agent_os_state,
                worker.run_id(),
                worker.host_process_epoch(),
                worker.resource_lifecycle(),
            )?;
        }
        Ok(expired)
    }

    fn acknowledge_command(
        &self,
        acknowledgement: &HostCommandAcknowledgement,
    ) -> Result<HostCommandOutboxRow, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        let row = state
            .commands
            .get(acknowledgement.command_id())
            .cloned()
            .ok_or_else(not_found)?;
        validate_ack(&row, acknowledgement)?;
        if let Some(existing) = row.acknowledgement() {
            return if existing == acknowledgement {
                Ok(row)
            } else {
                Err(conflict())
            };
        }
        let worker = state
            .workers
            .get(row.run_id())
            .cloned()
            .ok_or_else(not_found)?;
        let session = state
            .sessions
            .get(row.session_handle())
            .cloned()
            .ok_or_else(not_found)?;
        let (worker, session, close_command) =
            apply_command_acknowledgement_state(&row, acknowledgement, &worker, &session)?;
        let acknowledged = row.with_acknowledgement(acknowledgement.clone());
        state
            .commands
            .insert(acknowledged.command_id().to_string(), acknowledged.clone());
        state.workers.insert(worker.run_id().to_string(), worker);
        state
            .sessions
            .insert(session.session_handle().to_string(), session);
        if let Some(close_command) = close_command {
            let close = HostCommandOutboxRow::pending(close_command);
            state.commands.insert(close.command_id().to_string(), close);
        }
        Ok(acknowledged)
    }

    fn apply_event_transactionally(
        &self,
        event: &LLMEventEnvelope,
        result: LLMEventSubmissionResult,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
        apply_event_in_memory(
            &self.inner,
            &self.failure,
            &self.agent_os_state,
            event,
            result,
        )
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

    fn event_receipt_by_id(
        &self,
        session_handle: &str,
        event_id: &str,
    ) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .event_receipts
            .values()
            .find(|receipt| {
                receipt.session_handle() == session_handle && receipt.event_id() == event_id
            })
            .cloned())
    }

    fn event_queue_usage(
        &self,
        session_handle: &str,
    ) -> Result<EventQueueUsage, RuntimeStateError> {
        let state = self.inner.lock().map_err(|_| poisoned())?;
        event_queue_usage_in_memory(&state, session_handle)
    }

    fn drain_inbound_events(
        &self,
        maximum: usize,
    ) -> Result<Vec<LLMEventEnvelope>, RuntimeStateError> {
        let mut state = self.inner.lock().map_err(|_| poisoned())?;
        drain_events_in_memory(&mut state, maximum)
    }

    fn turn_accumulator_events(
        &self,
        session_handle: &str,
        generation_turn_id: &str,
    ) -> Result<Vec<LLMEventEnvelope>, RuntimeStateError> {
        Ok(self
            .inner
            .lock()
            .map_err(|_| poisoned())?
            .turn_accumulators
            .get(&(session_handle.to_string(), generation_turn_id.to_string()))
            .cloned()
            .unwrap_or_default())
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
    failure: &Mutex<Option<RuntimeAggregateFailurePoint>>,
    agent_os_state: &SharedAgentOSStateStore,
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
    if matches!(
        result,
        LLMEventSubmissionResult::Backpressure
            | LLMEventSubmissionResult::StaleSession
            | LLMEventSubmissionResult::ClosedSession
    ) {
        return Ok(None);
    }
    let original = state.clone();
    let outcome = apply_event_in_memory_mutation(&mut state, failure, event, result);
    if outcome.is_ok() {
        let lifecycle = state
            .workers
            .get(event.run_id())
            .map(HostWorkerRecord::resource_lifecycle)
            .cloned();
        if let Some(lifecycle) = lifecycle {
            if let Err(error) = sync_in_memory_global_lease(
                agent_os_state,
                event.run_id(),
                event.host_process_epoch(),
                &lifecycle,
            ) {
                *state = original;
                return Err(error);
            }
        }
    }
    if outcome.is_err() {
        *state = original;
    }
    outcome
}

fn sync_in_memory_global_lease(
    state: &SharedAgentOSStateStore,
    run_id: &str,
    host_epoch: &str,
    lifecycle: &ResourceLifecycle,
) -> Result<(), RuntimeStateError> {
    state
        .with_mut(|repository| {
            let Some(lease) = repository.current_global_run_lease()? else {
                return Ok(());
            };
            if lease.owner_run_id() != Some(run_id) || lease.host_process_epoch() != host_epoch {
                return Ok(());
            }
            match lifecycle {
                ResourceLifecycle::AwaitingCloseCommandAck
                | ResourceLifecycle::AwaitingSessionClosed
                    if lease.state() == GlobalRunLeaseState::Active =>
                {
                    repository
                        .begin_release(lease.generation(), run_id, host_epoch)
                        .map(|_| ())
                }
                ResourceLifecycle::Closed { .. }
                    if lease.state() == GlobalRunLeaseState::Releasing =>
                {
                    repository.complete_release(lease.generation(), host_epoch)
                }
                _ => Ok(()),
            }
        })
        .map_err(|error| RuntimeStateError::new("llm.lease.transition_failed", error.to_string()))
}

fn apply_event_in_memory_mutation(
    state: &mut InMemoryRuntimeState,
    failure: &Mutex<Option<RuntimeAggregateFailurePoint>>,
    event: &LLMEventEnvelope,
    result: LLMEventSubmissionResult,
) -> Result<Option<LLMEventReceipt>, RuntimeStateError> {
    let worker = state
        .workers
        .get(event.run_id())
        .ok_or_else(not_found)?
        .clone();
    let session = state
        .sessions
        .get(event.session_handle())
        .ok_or_else(not_found)?
        .clone();
    if worker.session_handle() != event.session_handle()
        || worker.host_process_epoch() != event.host_process_epoch()
        || session.run_id() != event.run_id()
        || session.host_process_epoch() != event.host_process_epoch()
    {
        return Err(RuntimeStateError::new(
            "llm.event.identity_or_sequence_conflict",
            "event does not match worker and session identity",
        ));
    }

    if is_protocol_failure(result) {
        let (next_worker, next_session, close) =
            protocol_failure_state(&worker, &session, event, result)?;
        state
            .workers
            .insert(event.run_id().to_string(), next_worker);
        state
            .sessions
            .insert(event.session_handle().to_string(), next_session);
        if let Some(close) = close {
            state.commands.insert(
                close.command_id().to_string(),
                HostCommandOutboxRow::pending(close),
            );
            take_event_failure(failure, RuntimeAggregateFailurePoint::AfterEventOutboxWrite)?;
        }
        return Ok(None);
    }

    if worker.expected_event_sequence() != event.event_sequence()
        || event.expected_digest().map_err(contract_error)? != event.event_envelope_digest()
    {
        return Err(RuntimeStateError::new(
            "llm.event.identity_or_sequence_conflict",
            "event does not match the expected sequence or digest",
        ));
    }

    let disposition = event_receipt_disposition(event, result);
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
    take_event_failure(
        failure,
        RuntimeAggregateFailurePoint::AfterEventReceiptWrite,
    )?;

    let prior_events = event
        .generation_turn_id
        .as_deref()
        .and_then(|turn_id| {
            state
                .turn_accumulators
                .get(&(event.session_handle().to_string(), turn_id.to_string()))
        })
        .cloned()
        .unwrap_or_default();
    let (next_worker, next_session, close, terminal_events) =
        accepted_event_state(&worker, &session, event, result, &prior_events)?;
    state
        .workers
        .insert(event.run_id().to_string(), next_worker);
    take_event_failure(
        failure,
        RuntimeAggregateFailurePoint::AfterExpectedSequenceWrite,
    )?;

    if queues_inbound_event(event, result) {
        state.inbound_events.insert(
            (event.session_handle().to_string(), event.event_sequence()),
            event.clone(),
        );
    }
    take_event_failure(
        failure,
        RuntimeAggregateFailurePoint::AfterInboundEventWrite,
    )?;

    if let Some(turn_id) = event.generation_turn_id.as_deref() {
        state
            .turn_accumulators
            .entry((event.session_handle().to_string(), turn_id.to_string()))
            .or_default()
            .push(event.clone());
    }
    take_event_failure(
        failure,
        RuntimeAggregateFailurePoint::AfterEventAccumulatorWrite,
    )?;

    state
        .sessions
        .insert(event.session_handle().to_string(), next_session);
    take_event_failure(failure, RuntimeAggregateFailurePoint::AfterEventStateWrite)?;

    state
        .agent_events
        .entry(event.run_id().to_string())
        .or_default()
        .push((
            format!("llm.event.{}", event_kind_name(event.kind())),
            event.event_id().to_string(),
        ));
    state
        .agent_events
        .entry(event.run_id().to_string())
        .or_default()
        .extend(terminal_events);
    take_event_failure(failure, RuntimeAggregateFailurePoint::AfterEventAgentWrite)?;

    if let Some(close) = close {
        state.commands.insert(
            close.command_id().to_string(),
            HostCommandOutboxRow::pending(close),
        );
        take_event_failure(failure, RuntimeAggregateFailurePoint::AfterEventOutboxWrite)?;
    }
    Ok(Some(receipt))
}

fn take_event_failure(
    failure: &Mutex<Option<RuntimeAggregateFailurePoint>>,
    point: RuntimeAggregateFailurePoint,
) -> Result<(), RuntimeStateError> {
    let mut failure = failure.lock().map_err(|_| poisoned())?;
    if failure.as_ref() == Some(&point) {
        *failure = None;
        Err(transaction_failed())
    } else {
        Ok(())
    }
}

pub(crate) fn event_receipt_disposition(
    event: &LLMEventEnvelope,
    result: LLMEventSubmissionResult,
) -> LLMEventReceiptDisposition {
    match result {
        LLMEventSubmissionResult::TurnTerminal | LLMEventSubmissionResult::GenerationTerminal => {
            LLMEventReceiptDisposition::TerminallyIgnored
        }
        LLMEventSubmissionResult::PayloadTooLarge => LLMEventReceiptDisposition::TerminalFailure,
        _ if event.kind() == crate::llm_contracts::LLMEventKind::SessionClosed => {
            LLMEventReceiptDisposition::Closed
        }
        _ => LLMEventReceiptDisposition::Accepted,
    }
}

pub(crate) fn queues_inbound_event(
    event: &LLMEventEnvelope,
    result: LLMEventSubmissionResult,
) -> bool {
    result == LLMEventSubmissionResult::Accepted
        && event.kind() != crate::llm_contracts::LLMEventKind::SessionClosed
}

pub(crate) fn accepted_event_state(
    worker: &HostWorkerRecord,
    session: &HostSessionRecord,
    event: &LLMEventEnvelope,
    result: LLMEventSubmissionResult,
    prior_events: &[LLMEventEnvelope],
) -> Result<
    (
        HostWorkerRecord,
        HostSessionRecord,
        Option<HostCommandEnvelope>,
        Vec<(String, String)>,
    ),
    RuntimeStateError,
> {
    let mut next_worker = worker
        .clone()
        .with_revision(worker.revision() + 1)
        .with_expected_event_sequence(worker.expected_event_sequence() + 1);
    let mut lifecycle = worker.resource_lifecycle().clone();
    let mut close = None;
    let mut terminal_events = Vec::new();

    if result == LLMEventSubmissionResult::PayloadTooLarge {
        let code = "llm.event.payload_too_large".to_string();
        next_worker = next_worker
            .with_execution_phase(None)
            .with_logical_outcome(LogicalRunOutcome::Failed { code });
        lifecycle = ResourceLifecycle::AwaitingCloseCommandAck;
        let (armed, command) = arm_terminal_close(worker, next_worker)?;
        next_worker = armed;
        close = Some(command);
    } else if result == LLMEventSubmissionResult::Accepted {
        use crate::llm_contracts::LLMEventKind;
        match event.kind() {
            LLMEventKind::GenerationStarted => {
                next_worker = next_worker
                    .with_execution_phase(Some(HostExecutionPhase::ConsumingLlmTurn))
                    .with_watchdog(None, None, None);
                lifecycle = ResourceLifecycle::Generating;
            }
            LLMEventKind::GenerationCompleted => {
                let completion = event.payload.completion.as_ref().ok_or_else(|| {
                    RuntimeStateError::new(
                        "llm.event.invalid_envelope",
                        "generation completion payload is missing",
                    )
                })?;
                if completion.outcome == "tool_calls_ready"
                    && valid_tool_batch(completion, prior_events)
                {
                    next_worker = next_worker
                        .with_execution_phase(Some(HostExecutionPhase::ExecutingToolBatch));
                } else if completion.outcome == "final_response"
                    && valid_final_response(completion, prior_events)
                {
                    let turn_id = event.generation_turn_id.as_deref().ok_or_else(|| {
                        RuntimeStateError::new(
                            "llm.event.invalid_envelope",
                            "generation completion turn identity is missing",
                        )
                    })?;
                    let text = prior_events
                        .iter()
                        .filter(|event| event.kind() == LLMEventKind::TextDelta)
                        .filter_map(|event| event.payload.text.as_deref())
                        .collect::<String>();
                    let output_id = format!("assistant:{}:{turn_id}", worker.run_id());
                    terminal_events.push((
                        "assistant.output".into(),
                        serde_json::json!({
                            "finish_reason": completion.finish_reason,
                            "generation_turn_id": turn_id,
                            "message_id": output_id,
                            "text": text,
                        })
                        .to_string(),
                    ));
                    terminal_events.push((
                        "run.completed".into(),
                        serde_json::json!({
                            "finish_reason": completion.finish_reason,
                            "message_id": output_id,
                        })
                        .to_string(),
                    ));
                    next_worker = next_worker.with_execution_phase(None).with_logical_outcome(
                        LogicalRunOutcome::Succeeded {
                            finish_reason: completion.finish_reason.clone(),
                        },
                    );
                    lifecycle = ResourceLifecycle::AwaitingCloseCommandAck;
                    let (armed, command) = arm_terminal_close(worker, next_worker)?;
                    next_worker = armed;
                    close = Some(command);
                } else {
                    let code = "llm.turn.invalid_tool_batch".to_string();
                    next_worker = next_worker
                        .with_execution_phase(None)
                        .with_logical_outcome(LogicalRunOutcome::Failed { code });
                    lifecycle = ResourceLifecycle::AwaitingCloseCommandAck;
                    let (armed, command) = arm_terminal_close(worker, next_worker)?;
                    next_worker = armed;
                    close = Some(command);
                }
            }
            LLMEventKind::Failed => {
                next_worker = next_worker.with_execution_phase(None).with_logical_outcome(
                    LogicalRunOutcome::Failed {
                        code: event
                            .payload
                            .failure_code
                            .clone()
                            .unwrap_or_else(|| "llm.generation.failed".into()),
                    },
                );
                lifecycle = ResourceLifecycle::AwaitingCloseCommandAck;
                let (armed, command) = arm_terminal_close(worker, next_worker)?;
                next_worker = armed;
                close = Some(command);
            }
            LLMEventKind::Cancelled => {
                next_worker = next_worker
                    .with_execution_phase(None)
                    .with_logical_outcome(LogicalRunOutcome::Cancelled);
                lifecycle = ResourceLifecycle::AwaitingCloseCommandAck;
                let (armed, command) = arm_terminal_close(worker, next_worker)?;
                next_worker = armed;
                close = Some(command);
            }
            LLMEventKind::SessionClosed => {
                lifecycle = ResourceLifecycle::Closed {
                    disposition: HostSessionCloseDisposition::Closed,
                };
                next_worker = next_worker.with_watchdog(None, None, None);
            }
            _ => {}
        }
    }
    next_worker = next_worker.with_resource_lifecycle(lifecycle.clone());
    Ok((
        next_worker,
        session.clone().with_resource_lifecycle(lifecycle),
        close,
        terminal_events,
    ))
}

fn valid_final_response(
    completion: &crate::llm_contracts::LLMBackendCompletionWire,
    events: &[LLMEventEnvelope],
) -> bool {
    completion.ordered_call_ids.is_empty()
        && matches!(
            completion.finish_reason.as_str(),
            "stop" | "length" | "content_filtered" | "other"
        )
        && !events.iter().any(|event| {
            matches!(
                event.kind(),
                crate::llm_contracts::LLMEventKind::ToolCallStarted
                    | crate::llm_contracts::LLMEventKind::ToolCallArgumentsDelta
                    | crate::llm_contracts::LLMEventKind::ToolCallCompleted
            )
        })
}

fn valid_tool_batch(
    completion: &crate::llm_contracts::LLMBackendCompletionWire,
    events: &[LLMEventEnvelope],
) -> bool {
    if completion.finish_reason != "tool_calls" || completion.ordered_call_ids.is_empty() {
        return false;
    }
    let mut started = Vec::new();
    let mut completed = Vec::new();
    for event in events {
        match event.kind() {
            crate::llm_contracts::LLMEventKind::ToolCallStarted => {
                let Some(call_id) = event.payload.call_id.as_ref() else {
                    return false;
                };
                if call_id.is_empty()
                    || event.payload.name.as_deref().is_none_or(str::is_empty)
                    || started.contains(call_id)
                {
                    return false;
                }
                started.push(call_id.clone());
            }
            crate::llm_contracts::LLMEventKind::ToolCallCompleted => {
                let Some(call_id) = event.payload.call_id.as_ref() else {
                    return false;
                };
                if event.payload.name.as_deref().is_none_or(str::is_empty)
                    || event.payload.arguments_json.is_none()
                    || completed.contains(call_id)
                {
                    return false;
                }
                completed.push(call_id.clone());
            }
            _ => {}
        }
    }
    started == completed
        && completed == completion.ordered_call_ids
        && completion
            .ordered_call_ids
            .iter()
            .collect::<std::collections::BTreeSet<_>>()
            .len()
            == completion.ordered_call_ids.len()
}

pub(crate) fn is_protocol_failure(result: LLMEventSubmissionResult) -> bool {
    matches!(
        result,
        LLMEventSubmissionResult::SequenceGap
            | LLMEventSubmissionResult::SequenceConflict
            | LLMEventSubmissionResult::IdentityConflict
            | LLMEventSubmissionResult::InvalidEnvelope
    )
}

pub(crate) fn protocol_failure_state(
    worker: &HostWorkerRecord,
    session: &HostSessionRecord,
    _event: &LLMEventEnvelope,
    result: LLMEventSubmissionResult,
) -> Result<
    (
        HostWorkerRecord,
        HostSessionRecord,
        Option<HostCommandEnvelope>,
    ),
    RuntimeStateError,
> {
    let code = format!("llm.event.{}", submission_result_name(result));
    let lifecycle = if matches!(
        worker.resource_lifecycle(),
        ResourceLifecycle::Closed { .. }
    ) {
        worker.resource_lifecycle().clone()
    } else {
        ResourceLifecycle::AwaitingCloseCommandAck
    };
    let mut next = worker
        .clone()
        .with_revision(worker.revision() + 1)
        .with_execution_phase(None)
        .with_logical_outcome(LogicalRunOutcome::Interrupted { code })
        .with_resource_lifecycle(lifecycle.clone());
    let close = if matches!(lifecycle, ResourceLifecycle::AwaitingCloseCommandAck) {
        let (armed, command) = arm_terminal_close(worker, next)?;
        next = armed;
        Some(command)
    } else {
        None
    };
    Ok((
        next,
        session.clone().with_resource_lifecycle(lifecycle),
        close,
    ))
}

pub(crate) fn lifecycle_command(
    worker: &HostWorkerRecord,
    kind: HostCommandKind,
) -> Result<HostCommandEnvelope, RuntimeStateError> {
    let id = crate::llm_contracts::BearerTokenIssuer::system()
        .issue("saga-token:v1")
        .map_err(|error| RuntimeStateError::new("llm.command.id_failed", error.to_string()))?
        .raw()
        .to_string();
    HostCommandEnvelope::lifecycle(
        id,
        worker.run_id(),
        worker.session_handle(),
        worker.host_process_epoch(),
        worker.expected_command_sequence(),
        kind,
    )
    .map_err(|error| RuntimeStateError::new("llm.command.invalid", error.to_string()))
}

fn arm_terminal_close(
    worker: &HostWorkerRecord,
    next: HostWorkerRecord,
) -> Result<(HostWorkerRecord, HostCommandEnvelope), RuntimeStateError> {
    let command = lifecycle_command(worker, HostCommandKind::CloseSession)?;
    let next = next
        .with_expected_command_sequence(worker.expected_command_sequence() + 1)
        .with_watchdog(
            Some(HostWatchdogKind::CloseCommandAck),
            Some(command.command_id().to_string()),
            Some(runtime_now_millis() + HOST_LIFECYCLE_TIMEOUT_MILLIS),
        );
    Ok((next, command))
}

pub(crate) fn expired_watchdog_state(
    worker: &HostWorkerRecord,
    session: &HostSessionRecord,
    now_millis: u64,
) -> Result<
    Option<(
        HostWorkerRecord,
        HostSessionRecord,
        Option<HostCommandEnvelope>,
    )>,
    RuntimeStateError,
> {
    let Some(kind) = worker.watchdog_kind() else {
        return Ok(None);
    };
    if worker
        .watchdog_deadline_millis()
        .is_none_or(|deadline| deadline > now_millis)
    {
        return Ok(None);
    }

    let mut next = worker
        .clone()
        .with_revision(worker.revision() + 1)
        .with_execution_phase(None)
        .with_watchdog(None, None, None);
    let (lifecycle, close) = match kind {
        HostWatchdogKind::SessionClose => (
            ResourceLifecycle::Quarantined {
                code: "llm.session.close_timeout".into(),
            },
            None,
        ),
        HostWatchdogKind::CloseCommandAck => (
            ResourceLifecycle::Quarantined {
                code: "llm.command.ack_timeout".into(),
            },
            None,
        ),
        HostWatchdogKind::CancelTerminal => {
            if matches!(worker.logical_outcome(), LogicalRunOutcome::Pending) {
                next = next.with_logical_outcome(LogicalRunOutcome::Cancelled);
            }
            let (armed, command) = arm_terminal_close(worker, next)?;
            next = armed;
            (ResourceLifecycle::AwaitingCloseCommandAck, Some(command))
        }
        HostWatchdogKind::GenerationStart
        | HostWatchdogKind::StreamIdle
        | HostWatchdogKind::ToolBatch => {
            let code = match kind {
                HostWatchdogKind::GenerationStart => "llm.generation.start_timeout",
                HostWatchdogKind::StreamIdle => "llm.stream.idle_timeout",
                HostWatchdogKind::ToolBatch => "llm.tool.batch_timeout",
                _ => unreachable!(),
            };
            if matches!(worker.logical_outcome(), LogicalRunOutcome::Pending) {
                next = next.with_logical_outcome(LogicalRunOutcome::Failed { code: code.into() });
            }
            let (armed, command) = arm_terminal_close(worker, next)?;
            next = armed;
            (ResourceLifecycle::AwaitingCloseCommandAck, Some(command))
        }
        HostWatchdogKind::StartCommandAck
        | HostWatchdogKind::ResumeCommandAck
        | HostWatchdogKind::CancelCommandAck => {
            return Ok(None);
        }
    };
    next = next.with_resource_lifecycle(lifecycle.clone());
    Ok(Some((
        next,
        session.clone().with_resource_lifecycle(lifecycle),
        close,
    )))
}

fn submission_result_name(result: LLMEventSubmissionResult) -> &'static str {
    match result {
        LLMEventSubmissionResult::SequenceGap => "sequence_gap",
        LLMEventSubmissionResult::SequenceConflict => "sequence_conflict",
        LLMEventSubmissionResult::IdentityConflict => "identity_conflict",
        LLMEventSubmissionResult::InvalidEnvelope => "invalid_envelope",
        _ => "protocol_violation",
    }
}

pub(crate) fn event_kind_name(kind: crate::llm_contracts::LLMEventKind) -> &'static str {
    use crate::llm_contracts::LLMEventKind;
    match kind {
        LLMEventKind::GenerationStarted => "generation_started",
        LLMEventKind::TextDelta => "text_delta",
        LLMEventKind::ReasoningSummaryDelta => "reasoning_summary_delta",
        LLMEventKind::ToolCallStarted => "tool_call_started",
        LLMEventKind::ToolCallArgumentsDelta => "tool_call_arguments_delta",
        LLMEventKind::ToolCallCompleted => "tool_call_completed",
        LLMEventKind::UsageUpdated => "usage_updated",
        LLMEventKind::GenerationCompleted => "generation_completed",
        LLMEventKind::Failed => "failed",
        LLMEventKind::Cancelled => "cancelled",
        LLMEventKind::SessionClosed => "session_closed",
    }
}

fn event_queue_usage_in_memory(
    state: &InMemoryRuntimeState,
    session_handle: &str,
) -> Result<EventQueueUsage, RuntimeStateError> {
    let events = state
        .inbound_events
        .iter()
        .filter(|((handle, _), _)| handle == session_handle)
        .map(|(_, event)| event);
    let mut usage = EventQueueUsage::default();
    for event in events {
        usage.event_count += 1;
        usage.byte_count += serde_json::to_vec(event)
            .map_err(|error| RuntimeStateError::new("llm.event.encode_failed", error.to_string()))?
            .len();
    }
    Ok(usage)
}

fn drain_events_in_memory(
    state: &mut InMemoryRuntimeState,
    maximum: usize,
) -> Result<Vec<LLMEventEnvelope>, RuntimeStateError> {
    if maximum == 0 {
        return Ok(Vec::new());
    }
    let Some(session_handle) = state
        .inbound_events
        .keys()
        .next()
        .map(|(handle, _)| handle.clone())
    else {
        return Ok(Vec::new());
    };
    let before = event_queue_usage_in_memory(state, &session_handle)?;
    let keys: Vec<_> = state
        .inbound_events
        .keys()
        .filter(|(handle, _)| handle == &session_handle)
        .take(maximum)
        .cloned()
        .collect();
    let drained = keys
        .into_iter()
        .filter_map(|key| state.inbound_events.remove(&key))
        .collect::<Vec<_>>();
    let after = event_queue_usage_in_memory(state, &session_handle)?;
    if (before.event_count >= HOST_EVENT_MAX_EVENTS || before.byte_count >= HOST_EVENT_MAX_BYTES)
        && after.event_count < HOST_EVENT_LOW_WATER_EVENTS
        && after.byte_count < HOST_EVENT_LOW_WATER_BYTES
    {
        let worker = state
            .workers
            .values()
            .find(|worker| worker.session_handle() == session_handle)
            .cloned()
            .ok_or_else(not_found)?;
        let command = lifecycle_command(&worker, HostCommandKind::CapacityAvailable)?;
        state.commands.insert(
            command.command_id().to_string(),
            HostCommandOutboxRow::pending(command),
        );
        state.workers.insert(
            worker.run_id().to_string(),
            worker
                .clone()
                .with_revision(worker.revision() + 1)
                .with_expected_command_sequence(worker.expected_command_sequence() + 1),
        );
    }
    Ok(drained)
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
