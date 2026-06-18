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
fn memory_candidate_requires_confirmation() {
    let candidate = MemoryCandidate::new("likes local agents");

    assert!(!candidate.confirmed);
    assert_eq!(candidate.text, "likes local agents");
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
