use crate::context::{ContextInjectionPolicy, PromptMessage};
use crate::core::{EventKind, RuntimeEvent};
use crate::tool::ToolResult;
use serde_json::Value;

#[derive(Clone, Debug, Default)]
pub struct BranchProjector;

impl BranchProjector {
    pub fn new() -> Self {
        Self
    }

    pub fn project(&self, branch: Vec<RuntimeEvent>) -> Vec<PromptMessage> {
        let mut messages = Vec::new();
        for event in branch {
            match event.kind {
                EventKind::UserMessage => messages.push(PromptMessage::User(event.payload)),
                EventKind::AssistantMessageCompleted => {
                    messages.push(PromptMessage::Assistant(event.payload));
                }
                EventKind::ToolResultMessage => {
                    if let Some(message) = project_tool_result(event.payload) {
                        messages.push(message);
                    }
                }
                EventKind::BranchSummaryCreated => {
                    messages.clear();
                    messages.push(PromptMessage::Summary(event.payload));
                }
                _ => {}
            }
        }

        messages
    }
}

fn project_tool_result(payload: String) -> Option<PromptMessage> {
    let Some(result) = ToolResult::from_event_payload(&payload) else {
        if declares_tool_result_type(&payload) {
            return None;
        }
        return Some(PromptMessage::ToolResult(payload));
    };

    if ContextInjectionPolicy::default().should_inject_tool_result(&result) {
        Some(PromptMessage::ToolResult(result.model_text))
    } else {
        None
    }
}

fn declares_tool_result_type(payload: &str) -> bool {
    serde_json::from_str::<Value>(payload)
        .ok()
        .and_then(|value| {
            value
                .get("type")
                .and_then(Value::as_str)
                .map(|kind| kind == "tool_result")
        })
        .unwrap_or(false)
}
