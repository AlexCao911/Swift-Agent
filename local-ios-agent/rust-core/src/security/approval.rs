use crate::core::{AgentError, EntryId, RunId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalDecision {
    Approved,
    Rejected,
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub run_id: RunId,
    pub tool_call_id: EntryId,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SuspendedRun {
    request: ApprovalRequest,
    decision: Option<ApprovalDecision>,
}

impl SuspendedRun {
    pub fn new(request: ApprovalRequest) -> Self {
        Self {
            request,
            decision: None,
        }
    }

    pub fn submit_decision(
        &mut self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ApprovalDecision, AgentError> {
        if self.request.approval_id != approval_id {
            return Err(AgentError::PolicyDenied(format!(
                "approval id mismatch: expected {}, got {approval_id}",
                self.request.approval_id
            )));
        }
        if self.decision.is_some() {
            return Err(AgentError::PolicyDenied(format!(
                "approval already resolved: {approval_id}"
            )));
        }
        self.decision = Some(decision.clone());
        Ok(decision)
    }

    pub fn is_resolved(&self) -> bool {
        self.decision.is_some()
    }
}
