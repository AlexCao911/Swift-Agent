use crate::core::{RunState, RuntimeEvent};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTurnResult {
    pub run_id: String,
    pub state: RunState,
    pub events: Vec<RuntimeEvent>,
    pub pending_tool_call_id: Option<String>,
}
