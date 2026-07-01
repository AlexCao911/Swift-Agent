use crate::core::{EntryId, RunId, SessionId};
use crate::security::{ApprovalGrant, DataEgressDecision};
use crate::tool::{CompiledToolRecipe, ToolCall};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolExecutionRequest {
    run_id: RunId,
    session_id: SessionId,
    tool_call_entry_id: EntryId,
    tool_call_id: String,
    tool_name: String,
    arguments_json: String,
    compiled_recipe: Option<CompiledToolRecipe>,
    egress_decision: Option<DataEgressDecision>,
    approval_grant: Option<ApprovalGrant>,
}

impl ToolExecutionRequest {
    pub fn new(
        run_id: RunId,
        session_id: SessionId,
        tool_call_entry_id: EntryId,
        call: ToolCall,
    ) -> Self {
        Self {
            run_id,
            session_id,
            tool_call_entry_id,
            tool_call_id: call.id,
            tool_name: call.name,
            arguments_json: call.arguments_json,
            compiled_recipe: None,
            egress_decision: None,
            approval_grant: None,
        }
    }

    pub(crate) fn with_compiled_recipe(
        mut self,
        compiled_recipe: Option<CompiledToolRecipe>,
    ) -> Self {
        self.compiled_recipe = compiled_recipe;
        self
    }

    pub(crate) fn with_egress_decision(mut self, decision: DataEgressDecision) -> Self {
        self.egress_decision = Some(decision);
        self
    }

    pub(crate) fn with_approval_grant(mut self, grant: ApprovalGrant) -> Self {
        self.approval_grant = Some(grant);
        self
    }

    pub fn run_id(&self) -> &RunId {
        &self.run_id
    }

    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }

    pub fn tool_call_entry_id(&self) -> &EntryId {
        &self.tool_call_entry_id
    }

    pub fn tool_call_id(&self) -> &str {
        &self.tool_call_id
    }

    pub fn tool_name(&self) -> &str {
        &self.tool_name
    }

    pub fn arguments_json(&self) -> &str {
        &self.arguments_json
    }

    pub fn compiled_recipe(&self) -> Option<&CompiledToolRecipe> {
        self.compiled_recipe.as_ref()
    }

    pub fn egress_decision(&self) -> Option<&DataEgressDecision> {
        self.egress_decision.as_ref()
    }

    pub fn approval_grant(&self) -> Option<&ApprovalGrant> {
        self.approval_grant.as_ref()
    }
}
