use crate::core::{AgentError, EntryId, RunId};
use crate::security::data_egress::{DataEgressDecision, DataFieldClass, EgressDestination};
use crate::security::ApprovalProtocolScope;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalId(String);

impl ApprovalId {
    pub(super) fn new(value: impl Into<String>) -> Self {
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
    pub(super) fn new(approval_id: ApprovalId, granted_for: OperationDescriptor) -> Self {
        Self {
            approval_id,
            granted_for,
            disclosure_id: None,
            destination: None,
            data_classes: Vec::new(),
            expires_at_millis: None,
        }
    }

    pub(super) fn from_scope(approval_id: ApprovalId, scope: &ApprovalScope) -> Self {
        match &scope.kind {
            ApprovalScopeKind::Operation { operation } => Self::new(approval_id, operation.clone()),
            ApprovalScopeKind::Egress {
                operation,
                disclosure_id,
                destination,
                data_classes,
            } => Self {
                approval_id,
                granted_for: operation.clone(),
                disclosure_id: Some(disclosure_id.clone()),
                destination: Some(destination.clone()),
                data_classes: data_classes.clone(),
                expires_at_millis: None,
            },
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
            && self.disclosure_id.as_deref() == Some(decision.disclosure_id().as_str())
            && self.destination.as_ref() == Some(decision.policy().destination())
            && self.data_classes == decision.policy().allowed_fields()
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
pub struct ApprovalScope {
    kind: ApprovalScopeKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ApprovalScopeKind {
    Operation {
        operation: OperationDescriptor,
    },
    Egress {
        operation: OperationDescriptor,
        disclosure_id: String,
        destination: EgressDestination,
        data_classes: Vec<DataFieldClass>,
    },
}

impl ApprovalScope {
    pub fn operation(operation: OperationDescriptor) -> Self {
        Self {
            kind: ApprovalScopeKind::Operation { operation },
        }
    }

    pub fn egress(
        operation: OperationDescriptor,
        decision: &DataEgressDecision,
    ) -> Result<Self, AgentError> {
        if !decision.allowlist_result().is_allowed() {
            return Err(AgentError::PolicyDenied(format!(
                "egress destination is not allowlisted: {}",
                decision.policy().destination().as_str()
            )));
        }

        Ok(Self {
            kind: ApprovalScopeKind::Egress {
                operation,
                disclosure_id: decision.disclosure_id().as_str().to_string(),
                destination: decision.policy().destination().clone(),
                data_classes: decision.policy().allowed_fields().to_vec(),
            },
        })
    }

    pub fn is_egress(&self) -> bool {
        matches!(self.kind, ApprovalScopeKind::Egress { .. })
    }

    pub fn protocol_scope(&self) -> ApprovalProtocolScope {
        match &self.kind {
            ApprovalScopeKind::Operation { operation } => ApprovalProtocolScope::Operation {
                operation: operation.as_str().to_string(),
            },
            ApprovalScopeKind::Egress {
                operation,
                disclosure_id,
                destination,
                data_classes,
            } => ApprovalProtocolScope::Egress {
                operation: operation.as_str().to_string(),
                disclosure_id: disclosure_id.clone(),
                destination: destination.as_str().to_string(),
                data_classes: data_classes
                    .iter()
                    .map(|data_class| data_class.as_str().to_string())
                    .collect(),
            },
        }
    }

    pub fn approval_message(&self, fallback_message: &str) -> String {
        match &self.kind {
            ApprovalScopeKind::Operation { .. } => fallback_message.to_string(),
            ApprovalScopeKind::Egress {
                operation,
                destination,
                data_classes,
                ..
            } => {
                let data_classes = data_classes
                    .iter()
                    .map(DataFieldClass::as_str)
                    .collect::<Vec<_>>()
                    .join(", ");
                format!(
                    "Allow {} to send {} to {}?",
                    operation.as_str(),
                    data_classes,
                    destination.as_str()
                )
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApprovalRequest {
    pub approval_id: String,
    pub run_id: RunId,
    pub tool_call_entry_id: EntryId,
    pub message: String,
    pub requires_local_authentication: bool,
    pub scope: ApprovalScope,
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
