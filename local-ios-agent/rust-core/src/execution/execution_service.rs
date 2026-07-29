use serde_json::json;

use crate::conversation::ConversationRunFrameRef;
use crate::execution::{
    ApprovalDecision, CompletedRunRegistry, ExecutionEvent, ExecutionEventLog,
    ExecutionEventStream, ExecutionStartError, RunDebugStore, RunLifecycleService,
    ToolApprovalService, ToolLoopService,
};
use crate::storage::agent_os_state::SharedAgentOSStateStore;

pub struct ExecutionService {
    event_log: ExecutionEventLog,
    completed_runs: CompletedRunRegistry,
    tool_approval: ToolApprovalService,
    tool_loop: ToolLoopService,
    #[allow(dead_code)]
    debug_store: RunDebugStore,
    run_lifecycle: RunLifecycleService,
}

impl ExecutionService {
    pub fn with_agent_os_state(
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
        state_store: SharedAgentOSStateStore,
        host_process_epoch: impl Into<String>,
    ) -> Self {
        let run_lifecycle = RunLifecycleService::with_agent_os_state(
            event_log.clone(),
            state_store,
            host_process_epoch,
        );
        Self {
            event_log,
            completed_runs,
            tool_approval: ToolApprovalService,
            tool_loop: ToolLoopService::default(),
            debug_store: RunDebugStore,
            run_lifecycle,
        }
    }

    pub fn observe_events(&self, run_id: &str, from_sequence: Option<u64>) -> Vec<ExecutionEvent> {
        self.event_log.replay(run_id, from_sequence)
    }

    pub fn observe_event_stream(
        &self,
        run_id: &str,
        from_sequence: Option<u64>,
    ) -> ExecutionEventStream {
        self.event_log.subscribe(run_id, from_sequence)
    }

    pub fn record_external_event(
        &self,
        run_id: &str,
        code: &str,
        payload: impl Into<String>,
    ) -> Result<(), ExecutionStartError> {
        self.event_log.append_with_payload(run_id, code, payload);
        self.run_lifecycle.release_if_terminal(run_id, code)?;
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
        self.event_log.append_with_payload(
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
        self.completed_runs
            .record_completed_with_text(run_id, message_id, frame_ref, text);
        Ok(())
    }

    pub fn tool_loop(&self) -> &ToolLoopService {
        &self.tool_loop
    }

    pub fn approve_tool(
        &self,
        id: impl Into<String>,
        decision: ApprovalDecision,
    ) -> Result<(), ExecutionStartError> {
        self.tool_approval
            .approve_tool(id, decision)
            .map_err(|message| ExecutionStartError::new("execution.approve_tool_failed", message))
    }
}
