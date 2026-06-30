use crate::core::{EntryId, RunId};

use serde::Serialize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ApprovalProtocolScope {
    Operation {
        operation: String,
    },
    Egress {
        operation: String,
        disclosure_id: String,
        destination: String,
        data_classes: Vec<String>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolRequest {
    pub approval_id: String,
    pub run_id: RunId,
    pub tool_call_entry_id: EntryId,
    pub message: String,
    pub requires_local_authentication: bool,
    pub scope: ApprovalProtocolScope,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalProtocolResponse {
    pub approval_id: String,
    pub approved: bool,
    pub reason: Option<String>,
}
