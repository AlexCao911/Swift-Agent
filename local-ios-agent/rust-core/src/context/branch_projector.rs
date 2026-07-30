use std::collections::BTreeSet;

use crate::context::{ContextCompactionCheckpoint, ContextInjectionPolicy, PromptMessage};
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
        let branch = apply_transcript_mutations(branch);
        if let Some(checkpoint) = branch.iter().rev().find_map(|event| {
            (event.kind == EventKind::BranchSummaryCreated)
                .then(|| serde_json::from_str::<ContextCompactionCheckpoint>(&event.payload).ok())
                .flatten()
        }) {
            return project_checkpointed_branch(branch, checkpoint);
        }

        let mut messages = Vec::new();
        for event in branch {
            match event.kind {
                EventKind::UserMessage => {
                    messages.push(project_user_message(event.payload, event.blob_refs))
                }
                EventKind::AssistantMessageCompleted => {
                    messages.push(PromptMessage::Assistant(event.payload));
                }
                EventKind::ToolCallRequested => {
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

fn apply_transcript_mutations(branch: Vec<RuntimeEvent>) -> Vec<RuntimeEvent> {
    let mut effective = Vec::with_capacity(branch.len());

    for mut event in branch {
        match event.kind {
            EventKind::TranscriptRetryRequested => {
                truncate_at_command_target(&mut effective, &event.payload, "anchor_event_id", true);
            }
            EventKind::MessageEdited => {
                let Some(command) = command_payload(&event.payload) else {
                    effective.clear();
                    continue;
                };
                let Some(target_id) = command.get("target_event_id").and_then(Value::as_str) else {
                    effective.clear();
                    continue;
                };
                let Some(target_index) = effective
                    .iter()
                    .rposition(|candidate| candidate.id.0 == target_id)
                else {
                    effective.clear();
                    continue;
                };
                let Some(replacement_text) =
                    command.get("replacement_text").and_then(Value::as_str)
                else {
                    effective.clear();
                    continue;
                };

                effective.truncate(target_index);
                event.kind = EventKind::UserMessage;
                event.payload = replacement_text.to_string();
                event.blob_refs = attachment_ids(&command, "replacement_attachments");
                effective.push(event);
            }
            EventKind::MessageDeleted => {
                truncate_at_command_target(
                    &mut effective,
                    &event.payload,
                    "target_event_id",
                    false,
                );
            }
            EventKind::ConversationCleared | EventKind::ConversationDeleted => effective.clear(),
            _ => effective.push(event),
        }
    }

    effective
}

fn truncate_at_command_target(
    effective: &mut Vec<RuntimeEvent>,
    payload: &str,
    field: &str,
    include_target: bool,
) {
    let Some(command) = command_payload(payload) else {
        effective.clear();
        return;
    };
    let Some(target_id) = command.get(field).and_then(Value::as_str) else {
        effective.clear();
        return;
    };
    let Some(target_index) = effective
        .iter()
        .rposition(|candidate| candidate.id.0 == target_id)
    else {
        effective.clear();
        return;
    };

    effective.truncate(target_index + usize::from(include_target));
}

fn command_payload(payload: &str) -> Option<Value> {
    // Mutation events are only created by ConversationCommandService, which validates
    // their target before committing. Treat malformed persisted events as a reset so
    // stale transcript content cannot silently remain model-visible.
    let value = serde_json::from_str::<Value>(payload).ok()?;
    value.get("command").cloned()
}

fn attachment_ids(command: &Value, field: &str) -> Vec<String> {
    command
        .get(field)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|attachment| {
            attachment
                .get("attachment_id")
                .and_then(Value::as_str)
                .map(ToString::to_string)
        })
        .collect()
}

fn project_checkpointed_branch(
    branch: Vec<RuntimeEvent>,
    checkpoint: ContextCompactionCheckpoint,
) -> Vec<PromptMessage> {
    let preserved = checkpoint
        .preserved_event_ids
        .iter()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    let mut messages = vec![PromptMessage::Summary(checkpoint.summary)];
    for event in branch {
        if event.kind == EventKind::BranchSummaryCreated
            || (event.sequence <= checkpoint.covered_through_sequence
                && !preserved.contains(event.id.0.as_str()))
        {
            continue;
        }
        project_event(event, &mut messages);
    }
    messages
}

fn project_event(event: RuntimeEvent, messages: &mut Vec<PromptMessage>) {
    match event.kind {
        EventKind::UserMessage => {
            messages.push(project_user_message(event.payload, event.blob_refs))
        }
        EventKind::AssistantMessageCompleted | EventKind::ToolCallRequested => {
            messages.push(PromptMessage::Assistant(event.payload));
        }
        EventKind::ToolResultMessage => {
            if let Some(message) = project_tool_result(event.payload) {
                messages.push(message);
            }
        }
        _ => {}
    }
}

fn project_user_message(payload: String, mut blob_refs: Vec<String>) -> PromptMessage {
    let parsed = serde_json::from_str::<Value>(&payload).ok();
    let command = parsed.as_ref().and_then(|value| value.get("command"));
    let text = command
        .and_then(|value| value.get("text"))
        .and_then(Value::as_str)
        .map(ToString::to_string)
        .unwrap_or(payload);

    if blob_refs.is_empty() {
        blob_refs = command
            .and_then(|value| value.get("attachments"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|attachment| {
                attachment
                    .get("attachment_id")
                    .and_then(Value::as_str)
                    .map(ToString::to_string)
            })
            .collect();
    }

    if blob_refs.is_empty() {
        PromptMessage::User(text)
    } else {
        PromptMessage::UserWithBlobRefs {
            content: text,
            blob_refs,
        }
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
    fn user_blob_refs_are_available_to_provider_projection() {
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

        assert_eq!(
            messages,
            vec![PromptMessage::UserWithBlobRefs {
                content: "hello".into(),
                blob_refs: vec!["local-agent-chat:v1:metadata".into()],
            }]
        );
    }
}
