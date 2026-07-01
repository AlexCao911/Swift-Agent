use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId, SessionTree};
use local_ios_agent_runtime::memory::{InMemoryEventStore, SqliteEventStore};

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

#[test]
fn session_tree_tracks_active_leaf() {
    let mut tree = SessionTree::new(SessionId("session_2".to_string()));
    let root = tree
        .append(None, EventKind::SessionCreated, "created")
        .unwrap();
    let user = tree
        .append(Some(root.clone()), EventKind::UserMessage, "hello")
        .unwrap();

    assert_eq!(tree.active_leaf(), Some(&user));
    let branch = tree.active_branch(&user).unwrap();
    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["created", "hello"]);
}

#[test]
fn session_tree_can_be_constructed_with_explicit_store() {
    let mut tree = SessionTree::with_store(
        SessionId("session_3".to_string()),
        InMemoryEventStore::new(),
    );
    let root = tree
        .append(None, EventKind::SessionCreated, "created")
        .unwrap();

    assert_eq!(tree.active_leaf(), Some(&root));
}

#[test]
fn session_tree_can_use_sqlite_event_store() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();
    let mut tree = SessionTree::with_store(SessionId("session_sqlite_tree".to_string()), store);

    let root = tree
        .append(None, EventKind::SessionCreated, "created")
        .unwrap();
    let user = tree
        .append(Some(root), EventKind::UserMessage, "hello")
        .unwrap();

    assert_eq!(tree.active_leaf(), Some(&user));
    let branch = tree.active_branch(&user).unwrap();
    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();
    assert_eq!(payloads, vec!["created", "hello"]);
}
