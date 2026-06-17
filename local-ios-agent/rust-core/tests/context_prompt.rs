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
