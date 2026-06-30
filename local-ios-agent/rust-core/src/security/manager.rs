use std::collections::HashMap;

use crate::core::{AgentError, EntryId, RunId};
use crate::security::{
    ApprovalDecision, ApprovalGrant, ApprovalId, ApprovalProtocolRequest, ApprovalProtocolResponse,
    ApprovalQueue, ApprovalRequest, ApprovalScope, AuditPolicy, PermissionScope, PermissionState,
    PolicyDecision, PolicyEngine, RiskLevel,
};

#[derive(Clone, Debug)]
pub struct SecurityManager {
    pub policy: PolicyEngine,
    pub audit_policy: AuditPolicy,
    approvals: ApprovalQueue,
    permissions: Vec<PermissionScope>,
    tool_permission_scopes: HashMap<String, String>,
}

impl SecurityManager {
    pub fn new() -> Self {
        Self {
            policy: PolicyEngine::default(),
            audit_policy: AuditPolicy,
            approvals: ApprovalQueue::new(),
            permissions: Vec::new(),
            tool_permission_scopes: HashMap::new(),
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

    pub fn set_tool_permission_scope(
        &mut self,
        tool_name: impl Into<String>,
        scope_name: impl Into<String>,
    ) {
        self.tool_permission_scopes
            .insert(tool_name.into(), scope_name.into());
    }

    pub fn decide_tool(&self, risk_level: &RiskLevel, tool_name: &str) -> PolicyDecision {
        if let Some(scope_name) = self.tool_permission_scopes.get(tool_name) {
            return self.policy.decide_with_permission(
                risk_level,
                tool_name,
                self.permission_state(scope_name),
            );
        }

        self.policy.decide(risk_level, tool_name)
    }

    pub fn request_approval(
        &mut self,
        approval_id: impl Into<String>,
        run_id: RunId,
        tool_call_entry_id: EntryId,
        message: impl Into<String>,
        requires_local_authentication: bool,
        scope: ApprovalScope,
    ) -> Result<ApprovalProtocolRequest, AgentError> {
        let approval_id = approval_id.into();
        let message = message.into();
        self.approvals.push(ApprovalRequest {
            approval_id: approval_id.clone(),
            run_id: run_id.clone(),
            tool_call_entry_id: tool_call_entry_id.clone(),
            message: message.clone(),
            requires_local_authentication,
            scope,
        })?;
        Ok(ApprovalProtocolRequest {
            approval_id,
            run_id,
            tool_call_entry_id,
            message,
            requires_local_authentication,
        })
    }

    pub fn pending_approvals(&self) -> Vec<ApprovalRequest> {
        self.approvals.pending()
    }

    pub fn pending_approval_requests(&self) -> Vec<ApprovalProtocolRequest> {
        self.pending_approvals()
            .into_iter()
            .map(|request| ApprovalProtocolRequest {
                approval_id: request.approval_id,
                run_id: request.run_id,
                tool_call_entry_id: request.tool_call_entry_id,
                message: request.message,
                requires_local_authentication: request.requires_local_authentication,
            })
            .collect()
    }

    pub fn resolve_approval(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<(ApprovalRequest, ApprovalDecision), AgentError> {
        let request = self.approvals.take(&response.approval_id).ok_or_else(|| {
            AgentError::PolicyDenied(format!(
                "approval request not pending: {}",
                response.approval_id
            ))
        })?;
        let decision = if response.approved {
            ApprovalDecision::Approved
        } else {
            ApprovalDecision::Rejected
        };

        Ok((request, decision))
    }

    pub fn issue_grant(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<ApprovalGrant, AgentError> {
        let (request, decision) = self.resolve_approval(response)?;
        if decision != ApprovalDecision::Approved {
            return Err(AgentError::PolicyDenied(format!(
                "approval rejected: {}",
                request.approval_id
            )));
        }

        Ok(ApprovalGrant::from_scope(
            ApprovalId::new(request.approval_id),
            &request.scope,
        ))
    }

    pub fn issue_egress_grant(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<ApprovalGrant, AgentError> {
        let (request, approval_decision) = self.resolve_approval(response)?;
        if approval_decision != ApprovalDecision::Approved {
            return Err(AgentError::PolicyDenied(format!(
                "approval rejected: {}",
                request.approval_id
            )));
        }
        if !request.scope.is_egress() {
            return Err(AgentError::PolicyDenied(format!(
                "approval scope is not egress: {}",
                request.approval_id
            )));
        }

        Ok(ApprovalGrant::from_scope(
            ApprovalId::new(request.approval_id),
            &request.scope,
        ))
    }
}
