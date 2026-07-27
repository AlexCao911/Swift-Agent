use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use crate::conversation::{
    ConversationFrameRepository, ConversationRunFrameRef, InMemoryConversationFrameRepository,
};
use crate::execution::{
    ApprovalDecision, CompletedRunRegistry, ExecutionEvent, ExecutionEventLog,
    ExecutionEventStream, ExecutionModelClient, ExecutionPlan, ExecutionPlanner,
    ExecutionReactWorker, ExecutionStartError, ExecutionToolExecutor, ExecutionToolObservation,
    InferenceSettingsService, RunDebugStore, RunHandle, RunLifecycleService, RuntimeOptions,
    StartExecutionRequest, ToolApprovalService, ToolLoopService, ToolLoopStartRequest,
};
use crate::run_snapshot::{RunSnapshotService, StartRunRequest};
use crate::storage::agent_os_state::SharedAgentOSStateStore;

pub struct ExecutionService<R: ConversationFrameRepository = InMemoryConversationFrameRepository> {
    parts: ExecutionServiceParts<R>,
}

pub struct ExecutionServiceParts<
    R: ConversationFrameRepository = InMemoryConversationFrameRepository,
> {
    pub frames: R,
    pub snapshot_service: Arc<RunSnapshotService>,
    pub planner: ExecutionPlanner,
    pub run_lifecycle: RunLifecycleService,
    pub event_log: ExecutionEventLog,
    pub completed_runs: CompletedRunRegistry,
    pub tool_approval: ToolApprovalService,
    pub tool_loop: ToolLoopService,
    pub debug_store: RunDebugStore,
    pub inference_settings: InferenceSettingsService,
    pub worker_mode: ExecutionWorkerMode,
    pub worker_dependencies: ExecutionWorkerDependencies,
    pub active_runs: ActiveExecutionRunRegistry,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionWorkerMode {
    ReactWorker,
    SyntheticAdapter,
}

#[derive(Clone)]
pub struct ExecutionWorkerDependencies {
    model: Arc<dyn ExecutionModelClient>,
    tools: Arc<dyn ExecutionToolExecutor>,
}

#[derive(Clone, Debug, Default)]
pub struct ActiveExecutionRunRegistry {
    inner: Arc<Mutex<BTreeMap<String, ActiveExecutionRun>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ActiveExecutionRun {
    frame_ref: ConversationRunFrameRef,
    plan: ExecutionPlan,
}

impl<R: ConversationFrameRepository> ExecutionService<R> {
    pub fn new(parts: ExecutionServiceParts<R>) -> Self {
        Self { parts }
    }

    pub fn with_runtime_parts(
        frames: R,
        snapshot_service: impl Into<Arc<RunSnapshotService>>,
        planner: ExecutionPlanner,
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
        worker_dependencies: ExecutionWorkerDependencies,
    ) -> Self {
        Self::with_runtime_parts_and_agent_os_state(
            frames,
            snapshot_service,
            planner,
            event_log,
            completed_runs,
            worker_dependencies,
            SharedAgentOSStateStore::in_memory(),
            default_execution_host_epoch(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_runtime_parts_and_agent_os_state(
        frames: R,
        snapshot_service: impl Into<Arc<RunSnapshotService>>,
        planner: ExecutionPlanner,
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
        worker_dependencies: ExecutionWorkerDependencies,
        state_store: SharedAgentOSStateStore,
        host_process_epoch: impl Into<String>,
    ) -> Self {
        let run_lifecycle = RunLifecycleService::with_agent_os_state(
            event_log.clone(),
            state_store,
            host_process_epoch,
        );
        Self::new(ExecutionServiceParts {
            frames,
            snapshot_service: snapshot_service.into(),
            planner,
            run_lifecycle,
            event_log,
            completed_runs,
            tool_approval: ToolApprovalService::default(),
            tool_loop: ToolLoopService::default(),
            debug_store: RunDebugStore,
            inference_settings: InferenceSettingsService::default(),
            worker_mode: ExecutionWorkerMode::ReactWorker,
            worker_dependencies,
            active_runs: ActiveExecutionRunRegistry::default(),
        })
    }

    pub fn start_run(
        &self,
        request: StartExecutionRequest,
    ) -> Result<RunHandle, ExecutionStartError> {
        let frame = self
            .parts
            .frames
            .get(request.conversation_run_frame_ref())
            .ok_or_else(|| {
                ExecutionStartError::new(
                    "execution.frame_ref_untrusted",
                    format!(
                        "conversation frame ref was not issued by conversation service: {}",
                        request.conversation_run_frame_ref().frame_id().as_str()
                    ),
                )
            })?;
        self.parts.run_lifecycle.acquire_legacy(request.run_id())?;
        let snapshot = match self
            .parts
            .snapshot_service
            .resolve_and_persist(StartRunRequest::new(
                request.agent_profile_id(),
                request.profile_revision_id(),
                request.user_intent(),
                request.conversation_run_frame_ref().clone(),
            )) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                self.parts.run_lifecycle.release_run(request.run_id())?;
                return Err(ExecutionStartError::new(error.code(), error.to_string()));
            }
        };
        let plan = match self.parts.planner.plan(snapshot) {
            Ok(plan) => plan,
            Err(error) => {
                self.parts.run_lifecycle.release_run(request.run_id())?;
                return Err(ExecutionStartError::new(error.code(), error.to_string()));
            }
        };

        let handle = self.parts.run_lifecycle.start_run(request.run_id());
        self.parts.active_runs.record(
            request.run_id(),
            request.conversation_run_frame_ref().clone(),
            plan.clone(),
        );
        let worker_result = match self.parts.worker_mode {
            ExecutionWorkerMode::ReactWorker => {
                let worker = ExecutionReactWorker::new(
                    self.parts.worker_dependencies.model.clone(),
                    self.parts.worker_dependencies.tools.clone(),
                    crate::execution::ExecutionContextInputAssembler::new(
                        self.parts.inference_settings.runtime_options(),
                    ),
                    self.parts.event_log.clone(),
                    self.parts.completed_runs.clone(),
                );
                worker
                    .run_with_plan(
                        request.run_id(),
                        &frame,
                        request.conversation_run_frame_ref(),
                        &plan,
                    )
                    .map_err(|message| {
                        ExecutionStartError::new("execution.react_worker_failed", message)
                    })
            }
            ExecutionWorkerMode::SyntheticAdapter => self
                .parts
                .tool_loop
                .start_synthetic_for_contract_tests(ToolLoopStartRequest::new(
                    request.run_id().to_string(),
                    frame,
                    plan,
                    self.parts.event_log.clone(),
                    self.parts.completed_runs.clone(),
                    request.conversation_run_frame_ref().clone(),
                ))
                .map_err(|error| ExecutionStartError::new(error.code(), error.to_string())),
        };
        if let Err(error) = worker_result {
            self.parts.run_lifecycle.release_run(request.run_id())?;
            self.parts.active_runs.remove(request.run_id());
            return Err(error);
        }

        self.release_if_run_terminal(request.run_id())?;

        Ok(handle)
    }

    pub fn observe_events(&self, run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent> {
        self.parts.event_log.replay(run_id, from_sequence)
    }

    pub fn observe_event_stream(
        &self,
        run_id: &str,
        from_sequence: Option<u64>,
    ) -> ExecutionEventStream {
        self.parts.event_log.subscribe(run_id, from_sequence)
    }

    pub fn has_active_run(&self, run_id: &str) -> bool {
        self.parts.active_runs.get(run_id).is_some()
    }

    pub fn submit_tool_observation(
        &self,
        run_id: &str,
        observation: ExecutionToolObservation,
    ) -> Result<Vec<ExecutionEvent>, ExecutionStartError> {
        let active_run = self.parts.active_runs.get(run_id).ok_or_else(|| {
            ExecutionStartError::new(
                "execution.run_not_found",
                format!("missing execution run: {run_id}"),
            )
        })?;
        let frame = self
            .parts
            .frames
            .get(&active_run.frame_ref)
            .ok_or_else(|| {
                ExecutionStartError::new(
                    "execution.frame_ref_untrusted",
                    format!(
                        "conversation frame ref is no longer available: {}",
                        active_run.frame_ref.frame_id().as_str()
                    ),
                )
            })?;
        let replay_before = self.parts.event_log.replay(run_id, Some(0));
        let from_sequence = replay_before
            .iter()
            .map(ExecutionEvent::sequence)
            .max()
            .unwrap_or(0);
        self.parts.event_log.append_with_payload(
            run_id,
            "tool_result_message",
            json!({
                "call_id": &observation.call_id,
                "model_text": &observation.model_text
            })
            .to_string(),
        );
        let mut observations = replay_before
            .iter()
            .filter_map(tool_observation_from_event)
            .collect::<Vec<_>>();
        observations.push(observation);
        let worker = self.react_worker();
        if let Err(message) = worker.run_with_plan_and_observations(
            run_id,
            &frame,
            &active_run.frame_ref,
            &active_run.plan,
            observations,
        ) {
            self.parts.run_lifecycle.release_run(run_id)?;
            self.parts.active_runs.remove(run_id);
            return Err(ExecutionStartError::new(
                "execution.react_worker_failed",
                message,
            ));
        }

        self.release_if_run_terminal(run_id)?;

        Ok(self.parts.event_log.replay(run_id, Some(from_sequence)))
    }

    pub fn record_external_event(
        &self,
        run_id: &str,
        code: &str,
        payload: impl Into<String>,
    ) -> Result<(), ExecutionStartError> {
        self.parts
            .event_log
            .append_with_payload(run_id, code, payload);
        if self.parts.run_lifecycle.release_if_terminal(run_id, code)? {
            self.parts.active_runs.remove(run_id);
        }
        Ok(())
    }

    pub fn record_external_completed(
        &self,
        run_id: &str,
        frame_ref: ConversationRunFrameRef,
        host_event_id: &str,
        message_id: &str,
        text: &str,
        finish_reason: &str,
    ) -> Result<(), ExecutionStartError> {
        self.parts.event_log.append_with_payload(
            run_id,
            "assistant_message_completed",
            json!({
                "finish_reason": finish_reason,
                "host_event_id": host_event_id,
                "message_id": message_id,
                "text": text,
            })
            .to_string(),
        );
        self.parts
            .completed_runs
            .record_completed_with_text(run_id, message_id, frame_ref, text);
        Ok(())
    }

    pub fn tool_loop(&self) -> &ToolLoopService {
        &self.parts.tool_loop
    }

    pub fn approve_tool(
        &self,
        id: impl Into<String>,
        decision: ApprovalDecision,
    ) -> Result<(), ExecutionStartError> {
        self.parts
            .tool_approval
            .approve_tool(id, decision)
            .map_err(|message| ExecutionStartError::new("execution.approve_tool_failed", message))
    }

    pub fn update_runtime_options(
        &self,
        options: RuntimeOptions,
    ) -> Result<(), ExecutionStartError> {
        self.parts
            .inference_settings
            .update_runtime_options(options)
            .map_err(|message| {
                ExecutionStartError::new("execution.update_runtime_options_failed", message)
            })
    }

    pub fn runtime_options(&self) -> Option<RuntimeOptions> {
        self.parts.inference_settings.runtime_options()
    }

    fn react_worker(
        &self,
    ) -> ExecutionReactWorker<Arc<dyn ExecutionModelClient>, Arc<dyn ExecutionToolExecutor>> {
        ExecutionReactWorker::new(
            self.parts.worker_dependencies.model.clone(),
            self.parts.worker_dependencies.tools.clone(),
            crate::execution::ExecutionContextInputAssembler::new(
                self.parts.inference_settings.runtime_options(),
            ),
            self.parts.event_log.clone(),
            self.parts.completed_runs.clone(),
        )
    }

    fn release_if_run_terminal(&self, run_id: &str) -> Result<(), ExecutionStartError> {
        let terminal = self
            .parts
            .event_log
            .replay(run_id, Some(0))
            .into_iter()
            .rev()
            .find(|event| {
                matches!(
                    event.code(),
                    "run.completed" | "run.failed" | "run.cancelled"
                )
            });
        if let Some(event) = terminal {
            self.parts
                .run_lifecycle
                .release_if_terminal(run_id, event.code())?;
            self.parts.active_runs.remove(run_id);
        }
        Ok(())
    }
}

impl ExecutionWorkerDependencies {
    pub fn new(
        model: Arc<dyn ExecutionModelClient>,
        tools: Arc<dyn ExecutionToolExecutor>,
    ) -> Self {
        Self { model, tools }
    }
}

impl ActiveExecutionRunRegistry {
    fn record(&self, run_id: &str, frame_ref: ConversationRunFrameRef, plan: ExecutionPlan) {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(run_id.to_string(), ActiveExecutionRun { frame_ref, plan });
    }

    fn get(&self, run_id: &str) -> Option<ActiveExecutionRun> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(run_id)
            .cloned()
    }

    fn remove(&self, run_id: &str) {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(run_id);
    }
}

fn default_execution_host_epoch() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT_EPOCH: AtomicU64 = AtomicU64::new(1);
    format!(
        "execution-{}-{}",
        std::process::id(),
        NEXT_EPOCH.fetch_add(1, Ordering::Relaxed)
    )
}

fn tool_observation_from_event(event: &ExecutionEvent) -> Option<ExecutionToolObservation> {
    if event.code() != "tool_result_message" {
        return None;
    }
    let payload: Value = serde_json::from_str(event.payload()).ok()?;
    Some(ExecutionToolObservation {
        call_id: payload.get("call_id")?.as_str()?.to_string(),
        model_text: payload.get("model_text")?.as_str()?.to_string(),
    })
}
