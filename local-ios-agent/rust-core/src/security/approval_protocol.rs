use crate::core::{EntryId, RunId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolRequest {
    pub approval_id: String,
    pub run_id: RunId,
    pub tool_call_entry_id: EntryId,
    pub message: String,
    pub requires_local_authentication: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolResponse {
    pub approval_id: String,
    pub approved: bool,
    pub reason: Option<String>,
}
