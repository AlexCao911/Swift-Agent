use crate::context::{ContextInjectionPolicy, PromptMessage};
use crate::core::{EventKind, RuntimeEvent};
use crate::tool::ToolResult;

#[derive(Clone, Debug, Default)]
pub struct BranchProjector;

impl BranchProjector {
    pub fn new() -> Self {
        Self
    }

    pub fn project(&self, branch: Vec<RuntimeEvent>) -> Vec<PromptMessage> {
        branch
            .into_iter()
            .filter_map(|event| match event.kind {
                EventKind::UserMessage => Some(PromptMessage::User(event.payload)),
                EventKind::AssistantMessageCompleted => {
                    Some(PromptMessage::Assistant(event.payload))
                }
                EventKind::ToolResultMessage => project_tool_result(event.payload),
                EventKind::BranchSummaryCreated => Some(PromptMessage::Summary(event.payload)),
                _ => None,
            })
            .collect()
    }
}

fn project_tool_result(payload: String) -> Option<PromptMessage> {
    let Some(result) = ToolResult::from_event_payload(&payload) else {
        return Some(PromptMessage::ToolResult(payload));
    };

    if ContextInjectionPolicy::default().should_inject_tool_result(&result) {
        Some(PromptMessage::ToolResult(result.model_text))
    } else {
        None
    }
}
