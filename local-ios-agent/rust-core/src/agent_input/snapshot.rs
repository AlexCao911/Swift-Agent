use std::collections::BTreeSet;
use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::canonical_digest::CanonicalDigestV1;
use crate::skills::validate_skill_descriptors;

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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentInputError {
    code: String,
    message: String,
}

#[derive(Serialize)]
struct SnapshotDigestDocument<'a> {
    ordered_prompt_documents: &'a [PromptDocumentSnapshot],
    skill_descriptors: &'a [SkillDescriptor],
    ordered_tool_definitions: &'a [ToolDefinitionSnapshot],
}

impl RunStartSnapshot {
    pub fn make(
        ordered_prompt_documents: Vec<PromptDocumentSnapshot>,
        skill_descriptors: Vec<SkillDescriptor>,
        ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
    ) -> Result<Self, AgentInputError> {
        let mut snapshot = Self {
            ordered_prompt_documents,
            skill_descriptors,
            ordered_tool_definitions,
            snapshot_digest: String::new(),
        };
        snapshot.validate_fields()?;
        snapshot.snapshot_digest = snapshot.recomputed_digest()?;
        Ok(snapshot)
    }

    pub fn validate(&self) -> Result<(), AgentInputError> {
        self.validate_fields()?;
        if self.snapshot_digest.len() != 64
            || !self
                .snapshot_digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            || self.snapshot_digest != self.recomputed_digest()?
        {
            return Err(AgentInputError::new(
                "run_start_snapshot.digest_mismatch",
                "run-start snapshot digest does not match its frozen contents",
            ));
        }
        Ok(())
    }

    pub fn recomputed_digest(&self) -> Result<String, AgentInputError> {
        CanonicalDigestV1::digest(
            "run-start-snapshot:v1",
            &SnapshotDigestDocument {
                ordered_prompt_documents: &self.ordered_prompt_documents,
                skill_descriptors: &self.skill_descriptors,
                ordered_tool_definitions: &self.ordered_tool_definitions,
            },
        )
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| AgentInputError::new(error.code(), error.to_string()))
    }

    fn validate_fields(&self) -> Result<(), AgentInputError> {
        require_unique(
            self.ordered_prompt_documents
                .iter()
                .map(|document| document.id.as_str()),
            "run_start_snapshot.duplicate_prompt_document_id",
        )?;
        require_unique(
            self.ordered_tool_definitions
                .iter()
                .map(|tool| tool.name.as_str()),
            "run_start_snapshot.duplicate_tool_name",
        )?;
        validate_skill_descriptors(&self.skill_descriptors)?;

        if self.ordered_prompt_documents.iter().any(|document| {
            document.id.is_empty() || document.source.is_empty() || document.source.starts_with('/')
        }) {
            return Err(AgentInputError::new(
                "run_start_snapshot.prompt_document_invalid",
                "prompt document id and source must be non-empty product identifiers",
            ));
        }
        if self.ordered_tool_definitions.iter().any(|tool| {
            tool.name.is_empty()
                || !matches!(
                    tool.input_schema.as_object().and_then(|value| value.get("type")),
                    Some(Value::String(kind)) if kind == "object"
                )
        }) {
            return Err(AgentInputError::new(
                "run_start_snapshot.tool_schema_not_object",
                "every tool must have a name and an object JSON schema",
            ));
        }
        Ok(())
    }
}

impl AgentInputError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for AgentInputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for AgentInputError {}

fn require_unique<'a>(
    values: impl Iterator<Item = &'a str>,
    code: &'static str,
) -> Result<(), AgentInputError> {
    let mut seen = BTreeSet::new();
    for value in values {
        if !seen.insert(value) {
            return Err(AgentInputError::new(
                code,
                "snapshot identifiers must be unique",
            ));
        }
    }
    Ok(())
}
