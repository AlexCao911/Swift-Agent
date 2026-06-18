use serde_json::Value;

use crate::core::AgentError;
use crate::tool::ToolCall;

#[derive(Clone, Debug, Default)]
pub struct ToolCallParser;

impl ToolCallParser {
    pub fn new() -> Self {
        Self
    }

    pub fn parse(&self, json: &str) -> Result<ToolCall, AgentError> {
        let value: Value = serde_json::from_str(json)
            .map_err(|error| AgentError::ToolParse(format!("invalid tool call JSON: {error}")))?;
        let id = value["id"]
            .as_str()
            .ok_or_else(|| AgentError::ToolParse("missing tool call id".to_string()))?
            .to_string();
        let name = value["name"]
            .as_str()
            .ok_or_else(|| AgentError::ToolParse("missing tool name".to_string()))?
            .to_string();
        let arguments = value
            .get("arguments")
            .ok_or_else(|| AgentError::ToolParse("missing tool arguments".to_string()))?;
        if !arguments.is_object() {
            return Err(AgentError::ToolParse(
                "tool arguments must be a JSON object".to_string(),
            ));
        }
        let arguments_json = arguments.to_string();

        Ok(ToolCall {
            id,
            name,
            arguments_json,
        })
    }
}
