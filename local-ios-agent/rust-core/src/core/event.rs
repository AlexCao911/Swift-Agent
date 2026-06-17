use crate::core::types::{EntryId, RunId, SessionId};

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
            depth,
            kind,
            payload: payload.into(),
            blob_refs: Vec::new(),
        }
    }
}
