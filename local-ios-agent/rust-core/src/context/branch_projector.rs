use crate::context::PromptMessage;
use crate::core::{EventKind, RuntimeEvent};

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
                EventKind::ToolResultMessage => Some(PromptMessage::ToolResult(event.payload)),
                EventKind::BranchSummaryCreated => Some(PromptMessage::ToolResult(event.payload)),
                _ => None,
            })
            .collect()
    }
}
