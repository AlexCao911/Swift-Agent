use crate::core::{AgentError, EntryId, RunId, SessionId};
use crate::security::{PolicyDecision, PolicyEngine};
use crate::tool::{
    RetentionPolicy, Sensitivity, ToolCall, ToolExecutionRequest, ToolRegistry, ToolResult,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToolRouteOutcome {
    ExecuteInSwift(ToolExecutionRequest),
    ApprovalRequired(ToolExecutionRequest),
    Denied(ToolResult),
}

#[derive(Clone, Debug)]
pub struct ToolRouter {
    registry: ToolRegistry,
    policy: PolicyEngine,
}

impl ToolRouter {
    pub fn new(registry: ToolRegistry) -> Self {
        Self {
            registry,
            policy: PolicyEngine,
        }
    }

    pub fn route(
        &self,
        run_id: &RunId,
        session_id: &SessionId,
        tool_call_entry_id: &EntryId,
        call: ToolCall,
    ) -> Result<ToolRouteOutcome, AgentError> {
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

        match self.policy.decide(&schema.risk_level, &schema.name) {
            PolicyDecision::Allow => Ok(ToolRouteOutcome::ExecuteInSwift(request)),
            PolicyDecision::RequireApproval(_) => Ok(ToolRouteOutcome::ApprovalRequired(request)),
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
}
