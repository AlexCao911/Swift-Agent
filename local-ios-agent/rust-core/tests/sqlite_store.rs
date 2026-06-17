use local_ios_agent_runtime::memory::SqliteEventStore;

#[test]
fn sqlite_store_opens_and_creates_schema() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");

    let store = SqliteEventStore::open(&db_path).unwrap();

    assert_eq!(store.schema_version().unwrap(), 1);
}
