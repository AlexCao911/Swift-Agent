use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, EntryId, EventKind, RuntimeEvent, SessionId,
};
use local_ios_agent_runtime::storage::InMemoryConversationStore;

fn event(
    stream: &str,
    id: &str,
    parent: Option<&str>,
    sequence: u64,
    kind: EventKind,
    payload: &str,
) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.into()),
        SessionId(stream.into()),
        parent.map(|value| EntryId(value.into())),
        None,
        sequence,
        u32::try_from(sequence - 1).unwrap(),
        kind,
        payload,
    )
}

fn send_payload(text: &str) -> String {
    serde_json::json!({
        "command": {
            "kind": "send",
            "text": text,
            "attachments": []
        }
    })
    .to_string()
}

#[test]
fn summaries_filter_tombstones_and_use_only_the_effective_transcript() {
    let mut store = InMemoryConversationStore::new();
    store
        .append(event(
            "active",
            "active-old",
            None,
            1,
            EventKind::UserMessage,
            &send_payload("Old confidential topic"),
        ))
        .unwrap();
    store
        .rename_session(&SessionId("active".into()), "Old confidential title".into())
        .unwrap();
    store
        .append(event(
            "active",
            "active-clear",
            Some("active-old"),
            2,
            EventKind::ConversationCleared,
            "{}",
        ))
        .unwrap();
    store
        .append(event(
            "active",
            "active-new",
            Some("active-clear"),
            3,
            EventKind::UserMessage,
            &send_payload("Fresh topic"),
        ))
        .unwrap();
    store
        .append(event(
            "archived",
            "archived-user",
            None,
            1,
            EventKind::UserMessage,
            &send_payload("Archived topic"),
        ))
        .unwrap();
    store
        .append(event(
            "archived",
            "archived-tombstone",
            Some("archived-user"),
            2,
            EventKind::ConversationArchived,
            "{}",
        ))
        .unwrap();
    store
        .append(event(
            "deleted",
            "deleted-user",
            None,
            1,
            EventKind::UserMessage,
            &send_payload("Deleted topic"),
        ))
        .unwrap();
    store
        .append(event(
            "deleted",
            "deleted-tombstone",
            Some("deleted-user"),
            2,
            EventKind::ConversationDeleted,
            "{}",
        ))
        .unwrap();

    let runtime = AgentRuntime::with_store(AgentRuntimeConfig::default(), store).unwrap();
    let summaries = runtime.conversation_summaries().unwrap();

    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].session_id, SessionId("active".into()));
    assert_eq!(summaries[0].title, "Fresh topic");
    assert!(summaries[0].search_text.contains("Fresh topic"));
    assert!(!summaries[0].search_text.contains("Old confidential topic"));
    assert!(!summaries[0].search_text.contains("Old confidential title"));
}
