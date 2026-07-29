use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::core::{EventKind, RuntimeEvent};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TranscriptProjectionKind {
    SessionCreated,
    ProviderChanged,
    ToolRegistered,
    UserMessage,
    TranscriptRetryRequested,
    MessageEdited,
    MessageDeleted,
    ConversationCleared,
    BranchCreated,
    ConversationArchived,
    ConversationDeleted,
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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TranscriptProjectionEvent {
    pub conversation_stream_id: String,
    pub sequence: u64,
    pub event_id: String,
    pub run_id: Option<String>,
    pub kind: TranscriptProjectionKind,
    pub payload: Value,
}

impl From<RuntimeEvent> for TranscriptProjectionEvent {
    fn from(event: RuntimeEvent) -> Self {
        let payload = serde_json::from_str(&event.payload)
            .unwrap_or_else(|_| Value::String(event.payload.clone()));
        Self {
            conversation_stream_id: event.session_id.0,
            sequence: event.sequence,
            event_id: event.id.0,
            run_id: event.run_id.map(|run_id| run_id.0),
            kind: event.kind.into(),
            payload,
        }
    }
}

impl From<EventKind> for TranscriptProjectionKind {
    fn from(kind: EventKind) -> Self {
        match kind {
            EventKind::SessionCreated => Self::SessionCreated,
            EventKind::ProviderChanged => Self::ProviderChanged,
            EventKind::ToolRegistered => Self::ToolRegistered,
            EventKind::UserMessage => Self::UserMessage,
            EventKind::TranscriptRetryRequested => Self::TranscriptRetryRequested,
            EventKind::MessageEdited => Self::MessageEdited,
            EventKind::MessageDeleted => Self::MessageDeleted,
            EventKind::ConversationCleared => Self::ConversationCleared,
            EventKind::BranchCreated => Self::BranchCreated,
            EventKind::ConversationArchived => Self::ConversationArchived,
            EventKind::ConversationDeleted => Self::ConversationDeleted,
            EventKind::AssistantMessageStarted => Self::AssistantMessageStarted,
            EventKind::AssistantTextDelta => Self::AssistantTextDelta,
            EventKind::AssistantMessageCompleted => Self::AssistantMessageCompleted,
            EventKind::ToolCallRequested => Self::ToolCallRequested,
            EventKind::ToolCallApproved => Self::ToolCallApproved,
            EventKind::ToolCallRejected => Self::ToolCallRejected,
            EventKind::ToolExecutionStarted => Self::ToolExecutionStarted,
            EventKind::ToolExecutionUpdate => Self::ToolExecutionUpdate,
            EventKind::ToolExecutionCompleted => Self::ToolExecutionCompleted,
            EventKind::ToolExecutionFailed => Self::ToolExecutionFailed,
            EventKind::ToolResultMessage => Self::ToolResultMessage,
            EventKind::RunSuspended => Self::RunSuspended,
            EventKind::RunResumed => Self::RunResumed,
            EventKind::CompactionCreated => Self::CompactionCreated,
            EventKind::BranchSummaryCreated => Self::BranchSummaryCreated,
            EventKind::RunCancelled => Self::RunCancelled,
            EventKind::RunFailed => Self::RunFailed,
        }
    }
}
