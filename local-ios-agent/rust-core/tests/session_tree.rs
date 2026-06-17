use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::memory::InMemoryEventStore;

fn event(id: &str, parent: Option<&str>, sequence: u64, depth: u32, payload: &str) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.to_string()),
        SessionId("session_1".to_string()),
        parent.map(|value| EntryId(value.to_string())),
        None,
        sequence,
        depth,
        EventKind::UserMessage,
        payload,
    )
}

#[test]
fn active_branch_returns_ancestors_in_order() {
    let mut store = InMemoryEventStore::new();
    store.append(event("root", None, 1, 0, "root")).unwrap();
    store.append(event("a", Some("root"), 2, 1, "a")).unwrap();
    store.append(event("b", Some("a"), 3, 2, "b")).unwrap();
    store
        .append(event("side", Some("root"), 4, 1, "side"))
        .unwrap();

    let branch = store
        .active_branch(
            &SessionId("session_1".to_string()),
            &EntryId("b".to_string()),
        )
        .unwrap();

    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["root", "a", "b"]);
}
