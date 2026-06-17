use local_ios_agent_runtime::context::MockTokenizer;
use local_ios_agent_runtime::core::{
    AgentRuntime, AgentRuntimeConfig, MockStreamingProvider, SendMessageInput,
};
use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionCursor, SessionId};
use local_ios_agent_runtime::memory::SqliteEventStore;

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

fn config() -> AgentRuntimeConfig {
    AgentRuntimeConfig {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        tokenizer: Box::new(MockTokenizer::new(100)),
        provider: Box::new(MockStreamingProvider::new()),
    }
}

#[test]
fn runtime_replays_sessions_from_sqlite() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let session_id = {
        let store = SqliteEventStore::open(&db_path).unwrap();
        let mut runtime = AgentRuntime::with_store(config(), store).unwrap();
        let session_id = runtime.create_session().unwrap();
        runtime
            .send_message(SendMessageInput {
                session_id: session_id.clone(),
                parent_event_id: None,
                text: "hello".into(),
            })
            .unwrap();
        session_id
    };

    let store = SqliteEventStore::open(&db_path).unwrap();
    let runtime = AgentRuntime::with_store(config(), store).unwrap();

    assert!(runtime.session_ids().contains(&session_id));
}
