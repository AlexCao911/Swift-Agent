use local_ios_agent_runtime::memory::{
    BlobRecord, BranchSummaryRecord, LongTermMemoryRecord, MemoryCandidate, SqliteEventStore,
};

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

#[test]
fn sqlite_uses_keyword_index_for_memory_search() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    assert!(store
        .table_names()
        .unwrap()
        .contains(&"long_term_memory_keywords".to_string()));

    store
        .upsert_memory(LongTermMemoryRecord {
            id: "mem_1".into(),
            text: "Alex prefers local-first private agents".into(),
            keywords: vec!["privacy".into()],
            confirmed: true,
        })
        .unwrap();
    store
        .upsert_memory(LongTermMemoryRecord {
            id: "mem_1".into(),
            text: "Alex prefers local-first private agents".into(),
            keywords: vec!["local-first".into()],
            confirmed: true,
        })
        .unwrap();

    assert!(store.search_memory("privacy").unwrap().is_empty());
    assert_eq!(store.search_memory("local-first").unwrap()[0].id, "mem_1");
}

#[test]
fn memory_candidate_requires_confirmation() {
    let candidate = MemoryCandidate::new("likes local agents");

    assert!(!candidate.confirmed);
    assert_eq!(candidate.text, "likes local agents");
}

#[test]
fn sqlite_persists_confirmed_memory_candidate() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();

    store
        .save_memory_candidate(MemoryCandidate::new("likes local agents").confirm())
        .unwrap();
    drop(store);

    let reopened = SqliteEventStore::open(&db_path).unwrap();

    assert_eq!(
        reopened.memory_candidates().unwrap(),
        vec![MemoryCandidate {
            text: "likes local agents".into(),
            confirmed: true,
        }]
    );
}

#[test]
fn sqlite_stores_blob_and_branch_summary() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    store
        .put_blob(BlobRecord {
            id: "blob_1".into(),
            path: "/tmp/image.png".into(),
            mime_type: "image/png".into(),
            byte_count: 42,
        })
        .unwrap();
    store
        .put_branch_summary(BranchSummaryRecord {
            session_id: "session_1".into(),
            leaf_id: "entry_9".into(),
            summary: "summary".into(),
        })
        .unwrap();

    assert_eq!(
        store.get_blob("blob_1").unwrap().unwrap().mime_type,
        "image/png"
    );
    assert_eq!(
        store
            .branch_summary("session_1", "entry_9")
            .unwrap()
            .unwrap()
            .summary,
        "summary"
    );
}

#[test]
fn sqlite_rejects_blob_byte_count_above_sqlite_integer_range() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    let result = store.put_blob(BlobRecord {
        id: "blob_large".into(),
        path: "/tmp/large.bin".into(),
        mime_type: "application/octet-stream".into(),
        byte_count: i64::MAX as u64 + 1,
    });

    assert!(result.is_err());
}

#[test]
fn sqlite_rejects_negative_blob_byte_count_from_storage() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let store = SqliteEventStore::open(&db_path).unwrap();
    drop(store);

    let conn = rusqlite::Connection::open(&db_path).unwrap();
    conn.execute(
        "
        insert into blobs(id, path, mime_type, byte_count)
        values (?1, ?2, ?3, ?4)
        ",
        rusqlite::params![
            "blob_negative",
            "/tmp/bad.bin",
            "application/octet-stream",
            -1
        ],
    )
    .unwrap();
    drop(conn);

    let reopened = SqliteEventStore::open(&db_path).unwrap();

    assert!(reopened.get_blob("blob_negative").is_err());
}

#[test]
fn sqlite_persists_audit_rows_and_provider_settings() {
    let tempdir = tempfile::tempdir().unwrap();
    let store = SqliteEventStore::open(tempdir.path().join("agent.sqlite")).unwrap();

    store
        .write_audit("session_1", "entry_1", "tool executed")
        .unwrap();
    store
        .save_provider_setting("active_provider", "mock")
        .unwrap();

    assert_eq!(
        store.audit_rows("session_1").unwrap()[0].summary,
        "tool executed"
    );
    assert_eq!(
        store.provider_setting("active_provider").unwrap(),
        Some("mock".into())
    );
}
