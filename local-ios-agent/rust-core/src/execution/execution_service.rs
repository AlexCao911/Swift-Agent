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
        Self::new(ExecutionServiceParts {
            frames,
            snapshot_service: snapshot_service.into(),
            planner,
            run_lifecycle: RunLifecycleService::new(event_log.clone()),
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
        let snapshot = self
            .parts
            .snapshot_service
            .resolve_and_persist(StartRunRequest::new(
                request.agent_profile_id(),
                request.profile_revision_id(),
                request.user_intent(),
                request.conversation_run_frame_ref().clone(),
            ))
            .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;
        let plan = self
            .parts
            .planner
            .plan(snapshot)
            .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;

        let handle = self.parts.run_lifecycle.start_run(request.run_id());
        self.parts.active_runs.record(
            request.run_id(),
            request.conversation_run_frame_ref().clone(),
            plan.clone(),
        );
        match self.parts.worker_mode {
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
                    })?;
            }
            ExecutionWorkerMode::SyntheticAdapter => {
                self.parts
                    .tool_loop
                    .start_synthetic_for_contract_tests(ToolLoopStartRequest::new(
                        request.run_id().to_string(),
                        frame,
                        plan,
                        self.parts.event_log.clone(),
                        self.parts.completed_runs.clone(),
                        request.conversation_run_frame_ref().clone(),
                    ))
                    .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;
            }
        }

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
        worker
            .run_with_plan_and_observations(
                run_id,
                &frame,
                &active_run.frame_ref,
                &active_run.plan,
                observations,
            )
            .map_err(|message| {
                ExecutionStartError::new("execution.react_worker_failed", message)
            })?;

        Ok(self.parts.event_log.replay(run_id, Some(from_sequence)))
    }

    pub fn record_external_event(&self, run_id: &str, code: &str, payload: impl Into<String>) {
        self.parts
            .event_log
            .append_with_payload(run_id, code, payload);
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
