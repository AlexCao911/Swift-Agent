use std::collections::HashMap;

use crate::core::AgentError;
use crate::security::ApprovalRequest;

#[derive(Clone, Debug, Default)]
pub struct ApprovalQueue {
    pending: HashMap<String, ApprovalRequest>,
}

impl ApprovalQueue {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, request: ApprovalRequest) -> Result<(), AgentError> {
        if self.pending.contains_key(&request.approval_id) {
            return Err(AgentError::PolicyDenied(format!(
                "duplicate approval id: {}",
                request.approval_id
            )));
        }
        self.pending.insert(request.approval_id.clone(), request);
        Ok(())
    }

    pub fn pending(&self) -> Vec<ApprovalRequest> {
        let mut pending: Vec<_> = self.pending.values().cloned().collect();
        pending.sort_by(|left, right| left.approval_id.cmp(&right.approval_id));
        pending
    }

    pub fn take(&mut self, approval_id: &str) -> Option<ApprovalRequest> {
        self.pending.remove(approval_id)
    }
}
