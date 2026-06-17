use local_ios_agent_runtime::context::{BranchProjector, PromptMessage};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};

fn event(id: &str, kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.into()),
        SessionId("session_1".into()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[test]
fn projector_preserves_model_visible_branch_events() {
    let messages = BranchProjector::new().project(vec![
        event("summary", EventKind::BranchSummaryCreated, "summary so far"),
        event("user", EventKind::UserMessage, "hello"),
        event("tool", EventKind::ToolResultMessage, "tool result"),
        event("assistant", EventKind::AssistantMessageCompleted, "done"),
    ]);

    assert_eq!(
        messages,
        vec![
            PromptMessage::ToolResult("summary so far".into()),
            PromptMessage::User("hello".into()),
            PromptMessage::ToolResult("tool result".into()),
            PromptMessage::Assistant("done".into()),
        ]
    );
}
