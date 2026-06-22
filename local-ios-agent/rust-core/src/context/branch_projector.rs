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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{EntryId, EventKind, RuntimeEvent, SessionId};

    #[test]
    fn user_blob_refs_do_not_leak_into_prompt_projection() {
        let mut event = RuntimeEvent::new(
            EntryId("entry_1".into()),
            SessionId("session_1".into()),
            None,
            None,
            1,
            0,
            EventKind::UserMessage,
            "hello",
        );
        event.blob_refs = vec!["local-agent-chat:v1:metadata".into()];

        let messages = BranchProjector::new().project(vec![event]);

        assert_eq!(messages, vec![PromptMessage::User("hello".into())]);
    }
}
