use std::sync::mpsc;
use std::time::Duration;

use local_ios_agent_runtime::core::{EntryId, EventKind, RuntimeEvent, SessionId};
use local_ios_agent_runtime::memory::{EventStore, SqliteEventStore};

fn event(id: &str, session: &str, sequence: u64) -> RuntimeEvent {
    RuntimeEvent::new(
        EntryId(id.to_string()),
        SessionId(session.to_string()),
        None,
        None,
        sequence,
        0,
        EventKind::UserMessage,
        "hello",
    )
}

#[test]
fn sqlite_event_store_waits_for_short_write_lock_instead_of_failing_busy() {
    let tempdir = tempfile::tempdir().unwrap();
    let db_path = tempdir.path().join("agent.sqlite");
    let mut blocked_store = SqliteEventStore::open(&db_path).unwrap();
    let locker = rusqlite::Connection::open(&db_path).unwrap();

    locker.execute_batch("begin immediate").unwrap();

    let (attempted_tx, attempted_rx) = mpsc::channel();
    let handle = std::thread::spawn(move || {
        attempted_tx.send(()).unwrap();
        blocked_store.append(event("entry_after_lock", "session_lock", 1))
    });

    attempted_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    locker.execute_batch("commit").unwrap();

    handle
        .join()
        .expect("sqlite append thread should not panic")
        .expect("sqlite append should wait for a short lock and then commit");

    let reopened = SqliteEventStore::open(&db_path).unwrap();
    assert!(reopened
        .get(
            &SessionId("session_lock".to_string()),
            &EntryId("entry_after_lock".to_string())
        )
        .is_ok());
}
