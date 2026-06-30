use crate::core::{EntryId, RunId, SessionId};
use crate::tool::{CompiledToolRecipe, ToolCall};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolExecutionRequest {
    pub run_id: RunId,
    pub session_id: SessionId,
    pub tool_call_entry_id: EntryId,
    pub tool_call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
    pub compiled_recipe: Option<CompiledToolRecipe>,
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
        }
    }

    pub fn with_compiled_recipe(mut self, compiled_recipe: Option<CompiledToolRecipe>) -> Self {
        self.compiled_recipe = compiled_recipe;
        self
    }
}
