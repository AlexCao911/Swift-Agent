use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use crate::conversation::{ConversationRunFrame, ConversationRunFrameRef};
use crate::execution::{CompletedRunRegistry, ExecutionEventLog, ExecutionPlan};

#[derive(Clone, Debug, Default)]
pub struct ToolLoopService {
    pending: Arc<Mutex<BTreeMap<String, ToolLoopStartRequest>>>,
}

#[derive(Debug)]
pub struct ToolLoopStartRequest {
    run_id: String,
    frame: ConversationRunFrame,
    plan: ExecutionPlan,
    event_log: ExecutionEventLog,
    completed_runs: CompletedRunRegistry,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolLoopStartError {
    code: String,
    message: String,
}

impl ToolLoopService {
    pub fn start(&self, request: ToolLoopStartRequest) -> Result<(), ToolLoopStartError> {
        // Phase-1 bridge adapter: the real worker will replace this synthetic completion.
        request.event_log.append(request.run_id(), "run.completed");
        request.completed_runs.record_completed(
            request.run_id(),
            "final_1",
            request.conversation_run_frame_ref().clone(),
        );
        self.pending
            .lock()
            .expect("tool loop pending registry poisoned")
            .insert(request.run_id.clone(), request);
        Ok(())
    }

    pub fn pending_count(&self) -> usize {
        self.pending
            .lock()
            .expect("tool loop pending registry poisoned")
            .len()
    }
}

impl ToolLoopStartRequest {
    pub fn new(
        run_id: String,
        frame: ConversationRunFrame,
        plan: ExecutionPlan,
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
        conversation_run_frame_ref: ConversationRunFrameRef,
    ) -> Self {
        Self {
            run_id,
            frame,
            plan,
            event_log,
            completed_runs,
            conversation_run_frame_ref,
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn frame(&self) -> &ConversationRunFrame {
        &self.frame
    }

    pub fn plan(&self) -> &ExecutionPlan {
        &self.plan
    }

    pub fn event_log(&self) -> &ExecutionEventLog {
        &self.event_log
    }

    pub fn completed_runs(&self) -> &CompletedRunRegistry {
        &self.completed_runs
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl ToolLoopStartError {
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

impl fmt::Display for ToolLoopStartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ToolLoopStartError {}
