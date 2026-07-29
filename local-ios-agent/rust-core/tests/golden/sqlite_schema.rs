use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::storage::{ConversationEventStore, SqliteConversationStore};

#[test]
fn sqlite_v1_legacy_fixture_migrates_without_losing_runtime_history() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let fixture = include_str!("../fixtures/golden/sqlite_schema/v1_legacy.sql");
    let conn = rusqlite::Connection::open(&db_path).unwrap();
    conn.execute_batch(fixture).unwrap();
    drop(conn);

    let store = SqliteConversationStore::open(&db_path).unwrap();

    assert_eq!(store.schema_version().unwrap(), 1);
    assert!(!store
        .table_names()
        .unwrap()
        .contains(&"provider_settings".to_string()));

    let event = store
        .get(
            &SessionId("session_legacy".to_string()),
            &EntryId("entry_legacy".to_string()),
        )
        .unwrap();
    assert_eq!(event.payload, "legacy payload");
    assert_eq!(event.created_at_millis, 0);

    let migrated = rusqlite::Connection::open(&db_path).unwrap();
    for (table, column) in [
        ("sessions", "archived"),
        ("sessions", "title_override"),
        ("events", "created_at_millis"),
    ] {
        assert!(
            table_has_column(&migrated, table, column),
            "{table}.{column} should be added by migration"
        );
    }
}

#[test]
fn clean_conversation_store_does_not_create_memory_backend_tables() {
    let tempdir = tempfile::tempdir().unwrap();
    let store =
        SqliteConversationStore::open(tempdir.path().join("agent.sqlite")).unwrap();
    let tables = store.table_names().unwrap();

    for memory_table in [
        "long_term_memory",
        "long_term_memory_keywords",
        "memory_candidates",
    ] {
        assert!(!tables.iter().any(|table| table == memory_table));
    }
}

fn table_has_column(conn: &rusqlite::Connection, table: &str, column: &str) -> bool {
    let mut statement = conn
        .prepare(&format!("pragma table_info({table})"))
        .unwrap();
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap();

    let mut columns = Vec::new();
    for row in rows {
        columns.push(row.unwrap());
    }
    columns.iter().any(|name| name == column)
}
