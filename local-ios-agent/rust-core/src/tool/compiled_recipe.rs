use crate::security::{ApprovalRequirement, CredentialRef};
use crate::tool::{HttpConnectorPolicy, ToolRecipeKind, WorkflowStep};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompiledToolRecipe {
    pub name: String,
    pub kind: ToolRecipeKind,
    pub approval_requirement: ApprovalRequirement,
    pub base_tools: Vec<String>,
    pub has_side_effects: bool,
    pub content: CompiledToolRecipeContent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CompiledToolRecipeContent {
    HttpConnector {
        endpoint: String,
        policy: HttpConnectorPolicy,
        credential_ref: Option<CredentialRef>,
    },
    PureTransform {
        expression: String,
    },
    Alias {
        base_tool_name: String,
    },
    Workflow {
        steps: Vec<WorkflowStep>,
    },
}
