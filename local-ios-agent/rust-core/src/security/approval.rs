use crate::core::{AgentError, EntryId, RunId};
use crate::security::data_egress::{DataEgressDecision, DataFieldClass, EgressDestination};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalId(String);

impl ApprovalId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OperationDescriptor(String);

impl OperationDescriptor {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApprovalRequirement {
    NotRequired,
    Required,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalGrant {
    approval_id: ApprovalId,
    granted_for: OperationDescriptor,
    disclosure_id: Option<String>,
    destination: Option<EgressDestination>,
    data_classes: Vec<DataFieldClass>,
    expires_at_millis: Option<u64>,
}

impl ApprovalGrant {
    pub fn new(approval_id: ApprovalId, granted_for: OperationDescriptor) -> Self {
        Self {
            approval_id,
            granted_for,
            disclosure_id: None,
            destination: None,
            data_classes: Vec::new(),
            expires_at_millis: None,
        }
    }

    pub fn for_egress(
        approval_id: ApprovalId,
        granted_for: OperationDescriptor,
        decision: &DataEgressDecision,
    ) -> Self {
        Self {
            approval_id,
            granted_for,
            disclosure_id: Some(decision.disclosure_id.as_str().to_string()),
            destination: Some(decision.policy.destination.clone()),
            data_classes: decision.policy.allowed_fields.clone(),
            expires_at_millis: None,
        }
    }

    pub fn matches(&self, operation: &OperationDescriptor) -> bool {
        &self.granted_for == operation
    }

    pub fn matches_egress(
        &self,
        operation: &OperationDescriptor,
        decision: &DataEgressDecision,
    ) -> bool {
        self.matches(operation)
            && self.disclosure_id.as_deref() == Some(decision.disclosure_id.as_str())
            && self.destination.as_ref() == Some(&decision.policy.destination)
            && self.data_classes == decision.policy.allowed_fields
    }

    pub fn approval_id(&self) -> &ApprovalId {
        &self.approval_id
    }

    pub fn expires_at_millis(&self) -> Option<u64> {
        self.expires_at_millis
    }
}

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
    pub tool_call_entry_id: EntryId,
    pub message: String,
    pub requires_local_authentication: bool,
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
