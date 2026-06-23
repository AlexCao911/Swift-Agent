use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::memory::EventStore;
use local_ios_agent_runtime::memory::SqliteEventStore;

fn sqlite_event(
    id: &str,
    parent: Option<&str>,
    sequence: u64,
    depth: u32,
    payload: &str,
) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.to_string()),
        SessionId("session_sqlite".to_string()),
        parent.map(|value| EntryId(value.to_string())),
        None,
        sequence,
        depth,
        EventKind::UserMessage,
        payload,
    )
}

#[test]
fn sqlite_store_opens_and_creates_schema() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");

    let store = SqliteEventStore::open(&db_path).unwrap();

    assert_eq!(store.schema_version().unwrap(), 1);
}

#[test]
fn sqlite_store_creates_event_tables() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();

    let tables = store.table_names().unwrap();

    assert!(tables.contains(&"sessions".to_string()));
    assert!(tables.contains(&"events".to_string()));
    assert!(tables.contains(&"event_paths".to_string()));
    assert!(tables.contains(&"audit_log".to_string()));
}

#[test]
fn sqlite_store_appends_and_reads_event() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut store = SqliteEventStore::open(&db_path).unwrap();
    let source_event = sqlite_event("root", None, 1, 0, "root");

    store.append(source_event.clone()).unwrap();

    let event = store
        .get(
            &SessionId("session_sqlite".to_string()),
            &EntryId("root".to_string()),
        )
        .unwrap();

    assert_eq!(event.payload, "root");
    assert_eq!(event.kind, EventKind::UserMessage);
    assert_eq!(event.created_at_millis, source_event.created_at_millis);
}

#[test]
fn sqlite_store_reconstructs_active_branch_from_closure_table() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut store = SqliteEventStore::open(&db_path).unwrap();

    store
        .append(sqlite_event("root", None, 1, 0, "root"))
        .unwrap();
    store
        .append(sqlite_event("plan", Some("root"), 2, 1, "plan"))
        .unwrap();
    store
        .append(sqlite_event("done", Some("plan"), 3, 2, "done"))
        .unwrap();
    store
        .append(sqlite_event("side", Some("root"), 4, 1, "side"))
        .unwrap();

    let branch = store
        .active_branch(
            &SessionId("session_sqlite".to_string()),
            &EntryId("done".to_string()),
        )
        .unwrap();

    let payloads: Vec<_> = branch.iter().map(|event| event.payload.as_str()).collect();

    assert_eq!(payloads, vec!["root", "plan", "done"]);
}

#[test]
fn sqlite_store_exposes_replay_queries() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut store = SqliteEventStore::open(&db_path).unwrap();

    store
        .append(sqlite_event("root", None, 1, 0, "root"))
        .unwrap();
    store
        .append(sqlite_event("leaf", Some("root"), 2, 1, "leaf"))
        .unwrap();

    assert_eq!(
        store.list_sessions().unwrap(),
        vec![SessionId("session_sqlite".into())]
    );
    assert_eq!(
        store
            .active_leaf(&SessionId("session_sqlite".into()))
            .unwrap(),
        Some(EntryId("leaf".into()))
    );
    assert_eq!(
        store
            .last_event(&SessionId("session_sqlite".into()))
            .unwrap()
            .unwrap()
            .payload,
        "leaf"
    );
}
