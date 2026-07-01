use std::collections::BTreeSet;
use std::fmt;
use std::sync::{Arc, Mutex};

use serde::Serialize;

use crate::execution::{ExecutionPlan, ExecutionStep};
use crate::run_snapshot::RunSnapshotId;
use crate::runtime::{
    CheckpointRecord, Effect, EffectDriver, IdempotencyKey, RecordingEffectDriver, TraceSpan,
};
use crate::storage::{
    ArchiveRecord, ArchiveStore, EventRecord, EventStore, InMemoryTransactionRunner,
    PendingStoreWrite, StorageError, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RunState {
    Created,
    Planning,
    Ready,
    Running,
    AwaitingApproval,
    AwaitingTool,
    AwaitingInference,
    Checkpointing,
    Cancelling,
    Failed,
    Completed,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeExecutionDebugTrace {
    run_id: String,
    source_snapshot_id: Option<u64>,
    state: String,
    events: Vec<RuntimeExecutionEventDebugSummary>,
    transactions: Vec<RuntimeTransactionDebugSummary>,
    last_checkpoint: Option<RuntimeCheckpointDebugSummary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeExecutionEventDebugSummary {
    sequence: u64,
    code: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeTransactionDebugSummary {
    name: String,
    event_codes: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct RuntimeCheckpointDebugSummary {
    checkpoint_id: String,
    can_resume: bool,
}

#[derive(Clone, Debug, Default)]
pub struct RunMachinePersistence {
    transaction_runner: InMemoryTransactionRunner,
    inner: Arc<Mutex<RunMachinePersistenceInner>>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RunMachinePersistenceSnapshot {
    last_checkpoint: Option<CheckpointRecord>,
    completed_idempotency_keys: Vec<String>,
}

#[derive(Debug, Default)]
struct RunMachinePersistenceInner {
    last_checkpoint: Option<CheckpointRecord>,
    completed_idempotency_keys: BTreeSet<String>,
}

pub struct RunMachine {
    state: RunState,
    run_id: String,
    execution_plan: Option<ExecutionPlan>,
    persistence: RunMachinePersistence,
    transaction_log: Vec<TransactionLogEntry>,
    transaction_open: bool,
    fake_inference_observed_open_transaction: bool,
    allow_noop_inference: bool,
    effect_driver: Option<Arc<dyn EffectDriver>>,
    source_snapshot_id: Option<RunSnapshotId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunMachineError {
    code: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TransactionLogEntry {
    name: String,
    event_codes: Vec<String>,
}

struct AppendRuntimeEventsOperation {
    event_store: crate::storage::InMemoryEventStore,
    archive_store: crate::storage::InMemoryArchiveStore,
    persistence: RunMachinePersistence,
    stream_id: String,
    event_codes: Vec<String>,
    archives: Vec<ArchiveRecord>,
    state_write: RuntimeStateWrite,
}

#[derive(Clone, Debug, Default)]
struct RuntimeStateWrite {
    checkpoint: Option<CheckpointRecord>,
    completed_idempotency_key: Option<String>,
}

struct PendingRuntimeStateWrite {
    persistence: RunMachinePersistence,
    state_write: RuntimeStateWrite,
}

pub type RunMachineResult<T> = Result<T, RunMachineError>;

impl RunMachine {
    pub fn fixture_completed() -> Self {
        Self {
            state: RunState::Completed,
            ..Self::fixture_created()
        }
    }

    pub fn fixture_with_fake_inference() -> Self {
        Self {
            state: RunState::Ready,
            allow_noop_inference: true,
            ..Self::fixture_created()
        }
    }

    pub fn fixture_with_effect_driver(driver: RecordingEffectDriver) -> Self {
        Self {
            state: RunState::Ready,
            effect_driver: Some(Arc::new(driver)),
            ..Self::fixture_created()
        }
    }

    pub fn fixture_with_persistence(persistence: RunMachinePersistence) -> Self {
        Self {
            state: RunState::Ready,
            persistence,
            ..Self::fixture_created()
        }
    }

    pub fn fixture_with_effect_driver_and_persistence(
        driver: RecordingEffectDriver,
        persistence: RunMachinePersistence,
    ) -> Self {
        Self {
            state: RunState::Ready,
            effect_driver: Some(Arc::new(driver)),
            persistence,
            ..Self::fixture_created()
        }
    }

    pub fn from_plan(plan: ExecutionPlan) -> Self {
        Self {
            state: RunState::Ready,
            source_snapshot_id: Some(plan.snapshot_id()),
            execution_plan: Some(plan),
            ..Self::fixture_created()
        }
    }

    pub fn from_plan_with_effect_driver<D>(plan: ExecutionPlan, driver: D) -> Self
    where
        D: EffectDriver + 'static,
    {
        Self {
            state: RunState::Ready,
            source_snapshot_id: Some(plan.snapshot_id()),
            execution_plan: Some(plan),
            effect_driver: Some(Arc::new(driver)),
            ..Self::fixture_created()
        }
    }

    pub fn state(&self) -> RunState {
        self.state
    }

    pub fn source_snapshot_id(&self) -> RunSnapshotId {
        self.source_snapshot_id
            .expect("run machine was not created from an execution plan")
    }

    pub fn run_to_completion(&mut self) -> RunMachineResult<()> {
        self.commit_transaction("run.start", &["run.started"])?;
        self.state = RunState::Running;

        for step in self.execution_steps() {
            match step.kind().as_str() {
                "context.assemble" => {
                    self.commit_transaction("context.assemble", &["context.assembled"])?;
                }
                "inference.generate" => {
                    self.ensure_model_input_budget()?;
                    self.record_model_call_started("redacted prompt archive", "context archive")?;
                    self.state = RunState::AwaitingInference;
                    self.drive_inference_effect()?;
                    self.state = RunState::Running;
                    self.record_model_call_completed()?;
                }
                unknown => {
                    return Err(RunMachineError::new(
                        "execution.step_unknown",
                        format!("unknown execution step: {unknown}"),
                    ));
                }
            }
        }

        self.state = RunState::Completed;
        Ok(())
    }

    pub fn record_model_call_started(
        &mut self,
        prompt_payload: impl Into<String>,
        context_payload: impl Into<String>,
    ) -> RunMachineResult<()> {
        self.ensure_run_started()?;
        let mut event_codes = vec!["model_call.started"];
        let archives =
            self.archive_records_for_trace(prompt_payload, context_payload, &mut event_codes);
        self.commit_transaction_with_archives("model_call.pre_call", &event_codes, archives)?;
        self.state = RunState::AwaitingInference;
        Ok(())
    }

    pub fn record_model_call_completed(&mut self) -> RunMachineResult<()> {
        self.commit_transaction("model_call.post_call", &["model_call.completed"])?;
        self.commit_checkpoint("checkpoint.commit", "checkpoint.committed")?;
        self.state = RunState::Completed;
        Ok(())
    }

    pub fn record_model_call_awaiting_tool(&mut self) -> RunMachineResult<()> {
        self.commit_transaction("model_call.post_call", &["model_call.completed"])?;
        self.commit_checkpoint("checkpoint.commit", "checkpoint.committed")?;
        self.state = RunState::AwaitingTool;
        Ok(())
    }

    pub fn record_model_call_awaiting_approval(&mut self) -> RunMachineResult<()> {
        self.commit_transaction("model_call.post_call", &["model_call.completed"])?;
        self.commit_checkpoint("checkpoint.commit", "checkpoint.committed")?;
        self.state = RunState::AwaitingApproval;
        Ok(())
    }

    pub fn record_model_call_failed(&mut self) -> RunMachineResult<()> {
        self.commit_transaction("model_call.post_call", &["model_call.failed"])?;
        self.commit_checkpoint("checkpoint.commit", "checkpoint.committed")?;
        self.state = RunState::Failed;
        Ok(())
    }

    pub fn event_codes(&self) -> Vec<String> {
        self.persistence
            .transaction_runner
            .event_store()
            .stream(&self.run_id)
            .unwrap_or_default()
            .into_iter()
            .map(|event| event.event_type().to_string())
            .collect()
    }

    pub fn archive_records(&self) -> Vec<ArchiveRecord> {
        self.persistence
            .transaction_runner
            .archive_store()
            .records()
    }

    pub fn transaction_event_codes(&self, transaction_name: &str) -> Vec<String> {
        self.transaction_log
            .iter()
            .find(|entry| entry.name == transaction_name)
            .map(|entry| entry.event_codes.clone())
            .unwrap_or_default()
    }

    pub fn fake_inference_observed_open_transaction(&self) -> bool {
        self.fake_inference_observed_open_transaction
    }

    pub fn run_next_effect(&mut self) -> RunMachineResult<()> {
        let effect = Effect::tool_invoke("effect_1");
        let idempotency_key =
            IdempotencyKey::new(format!("{}:{}", self.run_id, effect.effect_id()));
        let trace_span = TraceSpan::new(effect.kind().operation());
        if self
            .persistence
            .contains_idempotency_key(idempotency_key.as_str())
        {
            self.commit_transaction("effect.idempotent_replay", &["effect.idempotent_replay"])?;
            return Ok(());
        }
        let driver = self.effect_driver.clone().ok_or_else(|| {
            RunMachineError::new(
                "effect.driver_missing",
                "run machine requires an effect driver to run effects",
            )
        })?;

        self.commit_transaction("effect.start", &["effect.started"])?;
        match driver.drive(&effect, &idempotency_key, &trace_span) {
            Ok(_) => {
                self.commit_transaction_with_state(
                    "effect.complete",
                    &["effect.completed"],
                    RuntimeStateWrite {
                        checkpoint: Some(CheckpointRecord::new("checkpoint_1", true)),
                        completed_idempotency_key: Some(idempotency_key.as_str().to_string()),
                    },
                )?;
                Ok(())
            }
            Err(error) => {
                let code = error.code().to_string();
                self.commit_transaction_with_state(
                    "effect.fail",
                    &["effect.failed"],
                    RuntimeStateWrite {
                        checkpoint: Some(CheckpointRecord::new("checkpoint_1", true)),
                        completed_idempotency_key: None,
                    },
                )?;
                self.state = RunState::Failed;
                Err(RunMachineError::new(code, error.to_string()))
            }
        }
    }

    pub fn last_checkpoint(&self) -> Option<CheckpointRecord> {
        self.persistence.last_checkpoint()
    }

    pub fn debug_trace(&self) -> RuntimeExecutionDebugTrace {
        RuntimeExecutionDebugTrace {
            run_id: self.run_id.clone(),
            source_snapshot_id: self.source_snapshot_id.map(|id| id.as_u64()),
            state: self.state.as_str().to_string(),
            events: self
                .persistence
                .transaction_runner
                .event_store()
                .stream(&self.run_id)
                .unwrap_or_default()
                .into_iter()
                .map(|event| RuntimeExecutionEventDebugSummary {
                    sequence: event.sequence.as_u64(),
                    code: event.event_type().to_string(),
                })
                .collect(),
            transactions: self
                .transaction_log
                .iter()
                .map(|entry| RuntimeTransactionDebugSummary {
                    name: entry.name.clone(),
                    event_codes: entry.event_codes.clone(),
                })
                .collect(),
            last_checkpoint: self.last_checkpoint().map(|checkpoint| {
                RuntimeCheckpointDebugSummary {
                    checkpoint_id: checkpoint.checkpoint_id().to_string(),
                    can_resume: checkpoint.can_resume(),
                }
            }),
        }
    }

    pub fn resume_from_last_checkpoint(&mut self) -> RunMachineResult<()> {
        if self.state == RunState::Completed {
            return Err(RunMachineError::new(
                "run.transition.invalid",
                "terminal runs cannot resume from a checkpoint",
            ));
        }
        if self.state == RunState::Failed {
            let checkpoint = self.last_checkpoint().ok_or_else(|| {
                RunMachineError::new(
                    "run.checkpoint.missing",
                    "failed run cannot resume without a checkpoint",
                )
            })?;
            if !checkpoint.can_resume() {
                return Err(RunMachineError::new(
                    "run.checkpoint.not_resumable",
                    "last checkpoint is not resumable",
                ));
            }
            self.commit_transaction("checkpoint.resume", &["checkpoint.resumed"])?;
        }

        self.state = RunState::Running;
        Ok(())
    }

    fn fixture_created() -> Self {
        Self {
            state: RunState::Created,
            run_id: "run_1".to_string(),
            execution_plan: None,
            persistence: RunMachinePersistence::default(),
            transaction_log: Vec::new(),
            transaction_open: false,
            fake_inference_observed_open_transaction: false,
            allow_noop_inference: false,
            effect_driver: None,
            source_snapshot_id: None,
        }
    }

    fn commit_transaction(&mut self, name: &str, event_codes: &[&str]) -> RunMachineResult<()> {
        self.commit_transaction_with_state(name, event_codes, RuntimeStateWrite::default())
    }

    fn commit_transaction_with_archives(
        &mut self,
        name: &str,
        event_codes: &[&str],
        archives: Vec<ArchiveRecord>,
    ) -> RunMachineResult<()> {
        let event_codes = event_codes
            .iter()
            .map(|code| (*code).to_string())
            .collect::<Vec<_>>();
        self.commit_transaction_full(name, event_codes, archives, RuntimeStateWrite::default())
    }

    fn commit_transaction_with_state(
        &mut self,
        name: &str,
        event_codes: &[&str],
        state_write: RuntimeStateWrite,
    ) -> RunMachineResult<()> {
        self.commit_transaction_full(
            name,
            event_codes.iter().map(|code| (*code).to_string()).collect(),
            Vec::new(),
            state_write,
        )
    }

    fn commit_transaction_full(
        &mut self,
        name: &str,
        event_codes: Vec<String>,
        archives: Vec<ArchiveRecord>,
        state_write: RuntimeStateWrite,
    ) -> RunMachineResult<()> {
        let event_store = self.persistence.transaction_runner.event_store();
        let archive_store = self.persistence.transaction_runner.archive_store();
        let mut operation = AppendRuntimeEventsOperation {
            event_store,
            archive_store,
            persistence: self.persistence.clone(),
            stream_id: self.run_id.clone(),
            event_codes: event_codes.clone(),
            archives,
            state_write,
        };

        self.transaction_open = true;
        let result = self
            .persistence
            .transaction_runner
            .run(TransactionName::new(name), &mut operation);
        self.transaction_open = false;
        result.map_err(RunMachineError::from_storage)?;

        self.transaction_log.push(TransactionLogEntry {
            name: name.to_string(),
            event_codes,
        });
        Ok(())
    }

    fn drive_inference_effect(&mut self) -> RunMachineResult<()> {
        self.fake_inference_observed_open_transaction = self.transaction_open;
        let effect = Effect::inference_generate("model_call_1");
        let idempotency_key =
            IdempotencyKey::new(format!("{}:{}", self.run_id, effect.effect_id()));
        let trace_span = TraceSpan::new(effect.kind().operation());
        let Some(driver) = self.effect_driver.clone() else {
            if self.allow_noop_inference {
                return Ok(());
            }
            return Err(RunMachineError::new(
                "effect.driver_missing",
                "production execution plans require an inference effect driver",
            ));
        };
        driver
            .drive(&effect, &idempotency_key, &trace_span)
            .map(|_| ())
            .map_err(|error| RunMachineError::new(error.code(), error.to_string()))
    }

    fn commit_checkpoint(&mut self, name: &str, event_code: &str) -> RunMachineResult<()> {
        self.commit_transaction_full(
            name,
            vec![event_code.to_string()],
            Vec::new(),
            RuntimeStateWrite {
                checkpoint: Some(CheckpointRecord::new("checkpoint_1", true)),
                completed_idempotency_key: None,
            },
        )
    }

    fn ensure_run_started(&mut self) -> RunMachineResult<()> {
        if self.event_codes().is_empty() {
            self.commit_transaction("run.start", &["run.started"])?;
            self.state = RunState::Running;
        }
        Ok(())
    }

    fn ensure_model_input_budget(&self) -> RunMachineResult<()> {
        let max_model_input_tokens = self
            .execution_plan
            .as_ref()
            .map(|plan| plan.budgets().max_model_input_tokens())
            .unwrap_or(1);
        if max_model_input_tokens == 0 {
            return Err(RunMachineError::new(
                "execution.budget_exceeded",
                "execution plan model input budget cannot fit a model call",
            ));
        }
        Ok(())
    }

    fn execution_steps(&self) -> Vec<ExecutionStep> {
        self.execution_plan
            .as_ref()
            .map(|plan| plan.steps().to_vec())
            .unwrap_or_else(|| {
                ExecutionPlan::for_snapshot(RunSnapshotId::new(0))
                    .steps()
                    .to_vec()
            })
    }

    fn trace_config_captures_prompt_archive(&self) -> bool {
        self.execution_plan
            .as_ref()
            .map(|plan| plan.trace_config().capture_prompt_archive())
            .unwrap_or(true)
    }

    fn trace_config_captures_context_archive(&self) -> bool {
        self.execution_plan
            .as_ref()
            .map(|plan| plan.trace_config().capture_context_archive())
            .unwrap_or(true)
    }

    fn archive_records_for_trace(
        &self,
        prompt_payload: impl Into<String>,
        context_payload: impl Into<String>,
        event_codes: &mut Vec<&'static str>,
    ) -> Vec<ArchiveRecord> {
        let mut archives = Vec::new();
        if self.trace_config_captures_prompt_archive() {
            archives.push(ArchiveRecord::with_payload(
                self.run_id.clone(),
                "prompt",
                prompt_payload.into(),
            ));
            event_codes.insert(0, "prompt_archive.appended");
        }
        if self.trace_config_captures_context_archive() {
            archives.push(ArchiveRecord::with_payload(
                self.run_id.clone(),
                "context",
                context_payload.into(),
            ));
            let insert_at = event_codes
                .iter()
                .position(|code| *code == "model_call.started")
                .unwrap_or(event_codes.len());
            event_codes.insert(insert_at, "context_archive.appended");
        }
        archives
    }
}

impl RunMachineError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for RunMachineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RunMachineError {}

impl RunState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::Planning => "planning",
            Self::Ready => "ready",
            Self::Running => "running",
            Self::AwaitingApproval => "awaiting_approval",
            Self::AwaitingTool => "awaiting_tool",
            Self::AwaitingInference => "awaiting_inference",
            Self::Checkpointing => "checkpointing",
            Self::Cancelling => "cancelling",
            Self::Failed => "failed",
            Self::Completed => "completed",
        }
    }
}

impl RunMachineError {
    fn from_storage(error: StorageError) -> Self {
        Self::new(
            "run.storage_commit_failed",
            format!("runtime storage transaction failed: {error}"),
        )
    }
}

impl RunMachinePersistence {
    pub fn from_snapshot(snapshot: RunMachinePersistenceSnapshot) -> Self {
        Self {
            transaction_runner: InMemoryTransactionRunner::default(),
            inner: Arc::new(Mutex::new(RunMachinePersistenceInner {
                last_checkpoint: snapshot.last_checkpoint,
                completed_idempotency_keys: snapshot
                    .completed_idempotency_keys
                    .into_iter()
                    .collect(),
            })),
        }
    }

    pub fn export_snapshot(&self) -> RunMachinePersistenceSnapshot {
        let inner = self
            .inner
            .lock()
            .expect("run machine persistence mutex poisoned");
        RunMachinePersistenceSnapshot {
            last_checkpoint: inner.last_checkpoint.clone(),
            completed_idempotency_keys: inner.completed_idempotency_keys.iter().cloned().collect(),
        }
    }

    fn contains_idempotency_key(&self, key: &str) -> bool {
        self.inner
            .lock()
            .expect("run machine persistence mutex poisoned")
            .completed_idempotency_keys
            .contains(key)
    }

    fn last_checkpoint(&self) -> Option<CheckpointRecord> {
        self.inner
            .lock()
            .expect("run machine persistence mutex poisoned")
            .last_checkpoint
            .clone()
    }

    fn apply_state_write(&self, state_write: RuntimeStateWrite) {
        let mut inner = self
            .inner
            .lock()
            .expect("run machine persistence mutex poisoned");
        if let Some(checkpoint) = state_write.checkpoint {
            inner.last_checkpoint = Some(checkpoint);
        }
        if let Some(key) = state_write.completed_idempotency_key {
            inner.completed_idempotency_keys.insert(key);
        }
    }

    fn validate_state_write(&self, state_write: &RuntimeStateWrite) -> StorageResult<()> {
        if let Some(key) = &state_write.completed_idempotency_key {
            if self.contains_idempotency_key(key) {
                return Err(StorageError::new(
                    "runtime.idempotency_conflict",
                    "idempotency key was already completed",
                ));
            }
        }
        Ok(())
    }
}

impl RuntimeExecutionDebugTrace {
    pub fn state(&self) -> &str {
        &self.state
    }

    pub fn event_codes(&self) -> Vec<String> {
        self.events.iter().map(|event| event.code.clone()).collect()
    }
}

impl TransactionOperation for AppendRuntimeEventsOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        for archive in self.archives.drain(..) {
            self.archive_store.append_immutable(tx, archive)?;
        }
        for code in &self.event_codes {
            self.event_store
                .append(tx, EventRecord::new(self.stream_id.clone(), code.clone()))?;
        }
        if self.state_write.checkpoint.is_some()
            || self.state_write.completed_idempotency_key.is_some()
        {
            tx.push_store_write(Box::new(PendingRuntimeStateWrite {
                persistence: self.persistence.clone(),
                state_write: self.state_write.clone(),
            }));
        }
        Ok(())
    }
}

impl PendingStoreWrite for PendingRuntimeStateWrite {
    fn validate(&self) -> StorageResult<()> {
        self.persistence.validate_state_write(&self.state_write)
    }

    fn commit(self: Box<Self>) {
        self.persistence.apply_state_write(self.state_write);
    }
}
