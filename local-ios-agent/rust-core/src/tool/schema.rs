use serde_json::Value;

use crate::core::AgentError;
use crate::security::RiskLevel;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolSchema {
    pub name: String,
    pub description: String,
    pub parameters_json_schema: String,
    pub risk_level: RiskLevel,
    pub metadata_json: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments_json: String,
}

impl ToolCall {
    pub fn validate_shape(&self) -> Result<(), AgentError> {
        if self.id.trim().is_empty() {
            return Err(AgentError::ToolValidation(
                "tool call id must not be empty".to_string(),
            ));
        }
        if self.name.trim().is_empty() {
            return Err(AgentError::ToolValidation(
                "tool call name must not be empty".to_string(),
            ));
        }

        let arguments: Value = serde_json::from_str(&self.arguments_json).map_err(|error| {
            AgentError::ToolValidation(format!(
                "invalid arguments for tool `{}`: {error}",
                self.name
            ))
        })?;
        if !arguments.is_object() {
            return Err(AgentError::ToolValidation(format!(
                "arguments for tool `{}` must be a JSON object",
                self.name
            )));
        }

        Ok(())
    }
}
