use crate::execution::{
    CompletedRunRegistry, ExecutionEvent, ExecutionEventLog, InferenceSettingsService,
    RunDebugStore, RunHandle, RunLifecycleService, ToolApprovalService, ToolLoopService,
};

#[derive(Clone, Debug)]
pub struct ExecutionService {
    parts: ExecutionServiceParts,
}

#[derive(Clone, Debug)]
pub struct ExecutionServiceParts {
    pub run_lifecycle: RunLifecycleService,
    pub event_log: ExecutionEventLog,
    pub completed_runs: CompletedRunRegistry,
    pub tool_approval: ToolApprovalService,
    pub tool_loop: ToolLoopService,
    pub debug_store: RunDebugStore,
    pub inference_settings: InferenceSettingsService,
}

impl ExecutionService {
    pub fn new(parts: ExecutionServiceParts) -> Self {
        Self { parts }
    }

    pub fn start_run(&self, run_id: impl Into<String>) -> RunHandle {
        self.parts.run_lifecycle.start_run(run_id)
    }

    pub fn observe_events(&self, run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent> {
        self.parts.event_log.replay(run_id, from_sequence)
    }

    pub fn tool_loop(&self) -> &ToolLoopService {
        &self.parts.tool_loop
    }
}
