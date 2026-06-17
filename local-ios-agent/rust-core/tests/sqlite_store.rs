use local_ios_agent_runtime::memory::SqliteEventStore;

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
