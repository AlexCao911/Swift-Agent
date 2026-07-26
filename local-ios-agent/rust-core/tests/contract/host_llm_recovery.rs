use local_ios_agent_runtime::execution::ExecutionEventLog;
use local_ios_agent_runtime::llm_contracts::{
    HostCommandEnvelope, HostCommandKind, HostSessionCloseDisposition, HostSessionRecord,
    HostWorkerRecord, LogicalRunOutcome, ResourceLifecycle,
};
use local_ios_agent_runtime::storage::{
    HostCommandOutboxStatus, RuntimeTransition, SqliteRuntimeStateStore,
    UnifiedRuntimeStateRepository,
};

const OLD_EPOCH: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const NEW_EPOCH: &str = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";

#[test]
fn bootstrap_recovery_preserves_output_and_closes_every_old_host_continuation_once() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let store = SqliteRuntimeStateStore::open(&path).unwrap();
    store
        .agent_os_state()
        .with_mut(|repository| repository.acquire_legacy("run-old", OLD_EPOCH).map(|_| ()))
        .unwrap();
    let worker = HostWorkerRecord::new("run-old", "session-old", OLD_EPOCH);
    let session = HostSessionRecord::new(
        "run-old",
        "session-old",
        OLD_EPOCH,
        "binding-1",
        1,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    store
        .insert_worker_and_session(worker.clone(), session)
        .unwrap();
    let log = ExecutionEventLog::new(store.clone());
    log.append_with_payload("run-old", "assistant.output", r#"{"text":"kept"}"#);
    let close = HostCommandEnvelope::lifecycle(
        "close-old",
        "run-old",
        "session-old",
        OLD_EPOCH,
        1,
        HostCommandKind::CloseSession,
    )
    .unwrap();
    store
        .transition_and_enqueue(RuntimeTransition::new(
            0,
            worker
                .with_revision(1)
                .with_logical_outcome(LogicalRunOutcome::Succeeded {
                    finish_reason: "stop".into(),
                })
                .with_resource_lifecycle(ResourceLifecycle::AwaitingCloseCommandAck),
            close,
        ))
        .unwrap();

    let recovered = store.reconcile_for_host_epoch(NEW_EPOCH).unwrap();
    assert_eq!(recovered.len(), 1);
    assert!(matches!(
        recovered[0].logical_outcome(),
        LogicalRunOutcome::Interrupted { code }
            if code == "execution.llm_continuation_lost"
    ));
    assert_eq!(
        recovered[0].resource_lifecycle(),
        &ResourceLifecycle::Closed {
            disposition: HostSessionCloseDisposition::EpochEnded,
        }
    );
    assert!(store
        .agent_os_state()
        .with(|repository| repository.current_global_run_lease())
        .unwrap()
        .is_none());
    assert_eq!(
        store.host_command("close-old").unwrap().unwrap().status(),
        HostCommandOutboxStatus::Cancelled
    );
    let events = log.replay("run-old", None);
    assert!(events
        .iter()
        .any(|event| event.code() == "assistant.output"));
    assert!(events.iter().any(|event| {
        event.code() == "run.interrupted" && event.payload() == "execution.llm_continuation_lost"
    }));
    drop(log);
    drop(store);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    assert!(reopened
        .reconcile_for_host_epoch(NEW_EPOCH)
        .unwrap()
        .is_empty());
    assert_eq!(
        ExecutionEventLog::new(reopened)
            .replay("run-old", None)
            .iter()
            .filter(|event| event.code() == "run.interrupted")
            .count(),
        1
    );
}

#[test]
fn current_epoch_worker_is_never_recovered() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    store
        .insert_worker_and_session(
            HostWorkerRecord::new("run-current", "session-current", NEW_EPOCH),
            HostSessionRecord::new(
                "run-current",
                "session-current",
                NEW_EPOCH,
                "binding-1",
                1,
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ),
        )
        .unwrap();

    assert!(store
        .reconcile_for_host_epoch(NEW_EPOCH)
        .unwrap()
        .is_empty());
    assert!(matches!(
        store
            .host_worker("run-current")
            .unwrap()
            .unwrap()
            .logical_outcome(),
        LogicalRunOutcome::Pending
    ));
}
