use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PromptDocumentSnapshot {
    pub id: String,
    pub source: String,
    pub markdown: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SkillDescriptor {
    pub id: String,
    pub name: String,
    pub description: String,
    pub location: String,
    pub enabled: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolDefinitionSnapshot {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct RunStartSnapshot {
    pub ordered_prompt_documents: Vec<PromptDocumentSnapshot>,
    pub skill_descriptors: Vec<SkillDescriptor>,
    pub ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
    pub snapshot_digest: String,
}
