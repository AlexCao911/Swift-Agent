use local_ios_agent_runtime::context::{ContextController, MockTokenizer, PromptMessage};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};

fn message(kind: EventKind, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(format!("entry_{payload}")),
        SessionId("session_1".to_string()),
        None,
        None,
        1,
        0,
        kind,
        payload,
    )
}

#[test]
fn prompt_frame_injects_policy_tools_and_recent_messages() {
    let controller = ContextController::new(
        "system prompt",
        "runtime policy",
        vec!["calendar.search_events".to_string()],
        Box::new(MockTokenizer::new(100)),
    );

    let frame = controller
        .build_prompt_frame(vec![
            message(EventKind::UserMessage, "hello"),
            message(EventKind::AssistantMessageCompleted, "hi"),
        ])
        .unwrap();

    assert_eq!(frame.system_prompt, "system prompt");
    assert_eq!(frame.runtime_policy, "runtime policy");
    assert_eq!(frame.tool_schemas, vec!["calendar.search_events"]);
    assert_eq!(
        frame.messages,
        vec![
            PromptMessage::User("hello".to_string()),
            PromptMessage::Assistant("hi".to_string())
        ]
    );
}

#[test]
fn prompt_frame_truncates_oldest_messages_instead_of_erroring() {
    let controller = ContextController::new(
        "system",
        "policy",
        Vec::new(),
        Box::new(MockTokenizer::new(14)),
    );

    let frame = controller
        .build_prompt_frame(vec![
            message(EventKind::UserMessage, "old one two three"),
            message(EventKind::AssistantMessageCompleted, "old four"),
            message(EventKind::UserMessage, "new five six"),
        ])
        .unwrap();

    assert_eq!(
        frame.messages,
        vec![PromptMessage::User("new five six".to_string())]
    );
}

#[test]
fn prompt_frame_compacts_dropped_messages_after_existing_summary() {
    let controller = ContextController::new(
        "system",
        "policy",
        Vec::new(),
        Box::new(MockTokenizer::new(16)),
    );

    let result = controller
        .build_prompt_frame_with_compaction(vec![
            message(EventKind::BranchSummaryCreated, "old compacted context"),
            message(EventKind::UserMessage, "middle one two"),
            message(EventKind::AssistantMessageCompleted, "middle three four"),
            message(EventKind::UserMessage, "latest five"),
        ])
        .unwrap();

    assert_eq!(result.compaction_summary, Some("middle one two".into()));
    assert_eq!(
        result.frame.messages,
        vec![
            PromptMessage::Assistant("middle three four".into()),
            PromptMessage::User("latest five".into()),
        ]
    );
}
