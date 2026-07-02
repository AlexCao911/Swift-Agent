use std::sync::Arc;

use crate::conversation::{ConversationFrameRepository, InMemoryConversationFrameRepository};
use crate::execution::{
    ApprovalDecision, CompletedRunRegistry, ExecutionEvent, ExecutionEventLog,
    ExecutionEventStream, ExecutionPlanner, ExecutionStartError, InferenceSettingsService,
    RunDebugStore, RunHandle, RunLifecycleService, RuntimeOptions, StartExecutionRequest,
    ToolApprovalService, ToolLoopService, ToolLoopStartRequest,
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
            inference_settings: InferenceSettingsService,
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
        self.parts
            .tool_loop
            .start(ToolLoopStartRequest::new(
                request.run_id().to_string(),
                frame,
                plan,
                self.parts.event_log.clone(),
                self.parts.completed_runs.clone(),
                request.conversation_run_frame_ref().clone(),
            ))
            .map_err(|error| ExecutionStartError::new(error.code(), error.to_string()))?;

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
}
