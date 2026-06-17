use local_ios_agent_runtime::core::{
    AgentError, EntryId, EventKind, RunId, RuntimeEvent, SessionId,
};
use local_ios_agent_runtime::utils::id::IdGenerator;

#[test]
fn id_generator_produces_prefixed_monotonic_ids() {
    let ids = IdGenerator::new();

    assert_eq!(ids.next_id("entry"), "entry_1");
    assert_eq!(ids.next_id("entry"), "entry_2");
}

#[test]
fn agent_error_display_includes_category() {
    let error = AgentError::Provider("offline".to_string());

    assert_eq!(error.to_string(), "provider error: offline");
}

#[test]
fn runtime_event_captures_tree_and_run_metadata() {
    let event = RuntimeEvent::new(
        EntryId("entry_1".to_string()),
        SessionId("session_1".to_string()),
        Some(EntryId("entry_0".to_string())),
        Some(RunId("run_1".to_string())),
        7,
        2,
        EventKind::AssistantTextDelta,
        "hello",
    );

    assert_eq!(event.id, EntryId("entry_1".to_string()));
    assert_eq!(event.parent_id, Some(EntryId("entry_0".to_string())));
    assert_eq!(event.run_id, Some(RunId("run_1".to_string())));
    assert_eq!(event.sequence, 7);
    assert_eq!(event.depth, 2);
    assert_eq!(event.payload, "hello");
    assert!(event.blob_refs.is_empty());
}
