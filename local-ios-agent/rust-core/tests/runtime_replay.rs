use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionCursor, SessionId};

#[test]
fn cursor_replays_active_leaf_and_sequence() {
    let event = RuntimeEvent::new(
        EntryId("entry_3".into()),
        SessionId("session_1".into()),
        None,
        None,
        3,
        0,
        EventKind::UserMessage,
        "hello",
    );

    let cursor = SessionCursor::from_last_event(SessionId("session_1".into()), Some(event));

    assert_eq!(cursor.active_leaf, Some(EntryId("entry_3".into())));
    assert_eq!(cursor.next_sequence, 4);
}
