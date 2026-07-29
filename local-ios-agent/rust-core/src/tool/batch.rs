use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AgentToolCall {
    pub call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolBatch {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_calls: Vec<AgentToolCall>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolCallResult {
    pub call_id: String,
    pub tool_name: String,
    pub result: Value,
    pub is_error: bool,
    pub data_classes: Vec<String>,
    pub highest_sensitivity: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ToolBatchResult {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_results: Vec<ToolCallResult>,
}
