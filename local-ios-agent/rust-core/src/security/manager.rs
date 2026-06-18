use crate::core::{EntryId, RunId};
use crate::security::{
    ApprovalProtocolRequest, ApprovalQueue, ApprovalRequest, AuditPolicy, PermissionScope,
    PermissionState, PolicyEngine,
};

#[derive(Clone, Debug)]
pub struct SecurityManager {
    pub policy: PolicyEngine,
    pub audit_policy: AuditPolicy,
    approvals: ApprovalQueue,
    permissions: Vec<PermissionScope>,
}

impl SecurityManager {
    pub fn new() -> Self {
        Self {
            policy: PolicyEngine::default(),
            audit_policy: AuditPolicy,
            approvals: ApprovalQueue::new(),
            permissions: Vec::new(),
        }
    }

    pub fn set_permission(&mut self, scope: PermissionScope) {
        self.permissions
            .retain(|existing| existing.name != scope.name);
        self.permissions.push(scope);
    }

    pub fn permission_state(&self, name: &str) -> PermissionState {
        self.permissions
            .iter()
            .find(|scope| scope.name == name)
            .map(|scope| scope.state.clone())
            .unwrap_or(PermissionState::NotDetermined)
    }

    pub fn request_approval(
        &mut self,
        approval_id: impl Into<String>,
        message: impl Into<String>,
        requires_local_authentication: bool,
    ) -> ApprovalProtocolRequest {
        let approval_id = approval_id.into();
        let message = message.into();
        self.approvals.push(ApprovalRequest {
            approval_id: approval_id.clone(),
            run_id: RunId("pending".into()),
            tool_call_id: EntryId("pending".into()),
            message: message.clone(),
        });
        ApprovalProtocolRequest {
            approval_id,
            message,
            requires_local_authentication,
        }
    }

    pub fn pending_approvals(&self) -> Vec<ApprovalRequest> {
        self.approvals.pending()
    }
}
