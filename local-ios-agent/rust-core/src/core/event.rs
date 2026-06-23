use crate::core::types::{EntryId, RunId, SessionId};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventKind {
    SessionCreated,
    ProviderChanged,
    ToolRegistered,
    UserMessage,
    AssistantMessageStarted,
    AssistantTextDelta,
    AssistantMessageCompleted,
    ToolCallRequested,
    ToolCallApproved,
    ToolCallRejected,
    ToolExecutionStarted,
    ToolExecutionUpdate,
    ToolExecutionCompleted,
    ToolExecutionFailed,
    ToolResultMessage,
    RunSuspended,
    RunResumed,
    CompactionCreated,
    BranchSummaryCreated,
    RunCancelled,
    RunFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeEvent {
    pub id: EntryId,
    pub session_id: SessionId,
    pub parent_id: Option<EntryId>,
    pub run_id: Option<RunId>,
    pub sequence: u64,
    pub created_at_millis: u64,
    pub depth: u32,
    pub kind: EventKind,
    pub payload: String,
    pub blob_refs: Vec<String>,
}

impl RuntimeEvent {
    pub fn new(
        id: EntryId,
        session_id: SessionId,
        parent_id: Option<EntryId>,
        run_id: Option<RunId>,
        sequence: u64,
        depth: u32,
        kind: EventKind,
        payload: impl Into<String>,
    ) -> Self {
        Self {
            id,
            session_id,
            parent_id,
            run_id,
            sequence,
            created_at_millis: current_time_millis(),
            depth,
            kind,
            payload: payload.into(),
            blob_refs: Vec::new(),
        }
    }
}

fn current_time_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}
