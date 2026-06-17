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
        let id = value["id"].as_str().unwrap_or("call_1").to_string();
        let name = value["name"]
            .as_str()
            .ok_or_else(|| AgentError::ToolParse("missing tool name".to_string()))?
            .to_string();
        let arguments_json = value["arguments"].to_string();

        Ok(ToolCall {
            id,
            name,
            arguments_json,
        })
    }
}
