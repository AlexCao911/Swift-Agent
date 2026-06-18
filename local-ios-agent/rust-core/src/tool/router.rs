use std::collections::HashMap;

use crate::core::{AgentError, EntryId, RunId, SessionId};
use crate::security::{
    ApprovalDecision, ApprovalProtocolRequest, ApprovalProtocolResponse, ApprovalRequest,
    PolicyDecision, SecurityManager,
};
use crate::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolExecutionRequest, ToolRegistry, ToolResult,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToolRouteOutcome {
    ExecuteInSwift(ToolExecutionRequest),
    ApprovalRequired {
        request: ToolExecutionRequest,
        approval: ApprovalProtocolRequest,
        reason: String,
    },
    Denied(ToolResult),
}

#[derive(Clone, Debug)]
pub struct ToolRouter {
    registry: ToolRegistry,
    security: SecurityManager,
    suspended_tool_requests: HashMap<String, ToolExecutionRequest>,
}

impl ToolRouter {
    pub fn new(registry: ToolRegistry) -> Self {
        Self::with_security_manager(registry, SecurityManager::new())
    }

    pub fn with_security_manager(registry: ToolRegistry, security: SecurityManager) -> Self {
        Self {
            registry,
            security,
            suspended_tool_requests: HashMap::new(),
        }
    }

    pub fn route(
        &mut self,
        run_id: &RunId,
        session_id: &SessionId,
        tool_call_entry_id: &EntryId,
        call: ToolCall,
    ) -> Result<ToolRouteOutcome, AgentError> {
        call.validate_shape()?;
        let schema = self
            .registry
            .schema(&call.name)
            .ok_or_else(|| AgentError::ToolValidation(format!("unknown tool: {}", call.name)))?;
        let request = ToolExecutionRequest::new(
            run_id.clone(),
            session_id.clone(),
            tool_call_entry_id.clone(),
            call,
        );

        match self.security.decide_tool(&schema.risk_level, &schema.name) {
            PolicyDecision::Allow => Ok(ToolRouteOutcome::ExecuteInSwift(request)),
            PolicyDecision::RequireApproval(reason) => {
                let approval = self.security.request_approval(
                    format!("approval_{}", tool_call_entry_id.0),
                    run_id.clone(),
                    tool_call_entry_id.clone(),
                    reason.clone(),
                    true,
                );
                self.suspended_tool_requests
                    .insert(approval.approval_id.clone(), request.clone());
                Ok(ToolRouteOutcome::ApprovalRequired {
                    request,
                    approval,
                    reason,
                })
            }
            PolicyDecision::Deny(reason) => Ok(ToolRouteOutcome::Denied(ToolResult {
                display_text: reason.clone(),
                model_text: reason.clone(),
                structured_json: "{}".into(),
                audit_text: reason,
                sensitivity: Sensitivity::Public,
                retention: RetentionPolicy::RunOnly,
                is_error: true,
            })),
        }
    }

    pub fn pending_approvals(&self) -> Vec<ApprovalRequest> {
        self.security.pending_approvals()
    }

    pub fn pending_approval_requests(&self) -> Vec<ApprovalProtocolRequest> {
        self.security.pending_approval_requests()
    }

    pub fn resolve_approval(
        &mut self,
        response: ApprovalProtocolResponse,
    ) -> Result<
        (
            ApprovalRequest,
            ApprovalDecision,
            Option<ToolExecutionRequest>,
        ),
        AgentError,
    > {
        let (request, decision) = self.security.resolve_approval(response)?;
        let tool_request = self.suspended_tool_requests.remove(&request.approval_id);

        Ok((request, decision, tool_request))
    }
}
