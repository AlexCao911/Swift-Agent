use local_ios_agent_runtime::memory::{LongTermMemoryRecord, SqliteEventStore};

#[test]
fn sqlite_stores_and_searches_confirmed_memory() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    store
        .upsert_memory(LongTermMemoryRecord {
            id: "mem_1".into(),
            text: "Alex prefers local-first private agents".into(),
            keywords: vec!["local-first".into(), "privacy".into()],
            confirmed: true,
        })
        .unwrap();

    assert_eq!(store.search_memory("privacy").unwrap()[0].id, "mem_1");
}
