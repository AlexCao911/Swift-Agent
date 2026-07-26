use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use local_ios_agent_runtime::conversation::{
    ConversationFrameId, ConversationFrameMessage, ConversationLineage, ConversationRunFrame,
    ConversationRunFrameRef,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::execution::{ExecutionEventLog, HostLLMWorkerService};
use local_ios_agent_runtime::llm_contracts::{
    GlobalRunLeaseState, HostCommandAcknowledgement, HostCommandAcknowledgementDisposition,
    HostCommandEnvelope, HostExecutionPhase, HostSessionCloseDisposition, HostSessionRecord,
    HostWatchdogKind, HostWorkerRecord, LLMBackendCompletionWire, LLMEventEnvelope, LLMEventKind,
    LLMEventPayload, LLMEventReceiptDisposition, LLMEventSubmissionResult, LogicalRunOutcome,
    PreparedSessionRegistration, ResourceLifecycle,
};
use local_ios_agent_runtime::run_snapshot::{
    RunPreparationService, RunSnapshotService, StartRunRequest,
};
use local_ios_agent_runtime::storage::agent_os_state::SharedAgentOSStateStore;
use local_ios_agent_runtime::storage::{
    HostCommandOutboxStatus, InMemoryRuntimeStateStore, PreparedHostRunCommit,
    RuntimeAggregateFailurePoint, RuntimeAggregateInspection, RuntimeTransition,
    SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use local_ios_agent_runtime::user_customization::AgentProfileVersion;
use serde::de::DeserializeOwned;
use serde_json::Value;

#[test]
fn orthogonal_worker_axes_require_resource_close_for_full_terminal() {
    let worker = worker_fixture()
        .with_logical_outcome(LogicalRunOutcome::Succeeded {
            finish_reason: "stop".into(),
        })
        .with_resource_lifecycle(ResourceLifecycle::AwaitingSessionClosed);
    assert!(!worker.is_fully_terminal());

    let closed = worker.with_resource_lifecycle(ResourceLifecycle::Closed {
        disposition: HostSessionCloseDisposition::Closed,
    });
    assert!(closed.is_fully_terminal());
}

#[test]
fn worker_transition_and_outbox_are_one_in_memory_transaction() {
    let store = InMemoryRuntimeStateStore::new();
    store
        .insert_worker_and_session(worker_fixture(), session_fixture())
        .unwrap();
    store.inject_failure(RuntimeAggregateFailurePoint::AfterWorkerWrite);

    let error = store
        .transition_and_enqueue(transition_fixture())
        .unwrap_err();
    assert_eq!(error.code(), "llm.command.transaction_failed");
    assert_eq!(store.host_worker("run-1").unwrap().unwrap().revision(), 0);
    assert!(store.pending_host_commands().unwrap().is_empty());
}

#[test]
fn worker_transition_and_outbox_are_one_sqlite_transaction() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    store
        .insert_worker_and_session(worker_fixture(), session_fixture())
        .unwrap();
    store.inject_failure(RuntimeAggregateFailurePoint::AfterWorkerWrite);

    let error = store
        .transition_and_enqueue(transition_fixture())
        .unwrap_err();
    assert_eq!(error.code(), "llm.command.transaction_failed");
    assert_eq!(store.host_worker("run-1").unwrap().unwrap().revision(), 0);
    assert!(store.pending_host_commands().unwrap().is_empty());
}

#[test]
fn phase_c_failure_cannot_leave_a_partial_sqlite_aggregate() {
    for failure_point in RuntimeAggregateFailurePoint::phase_c_points() {
        let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
        let commit = prepared_commit_fixture(&store);
        store.inject_failure(failure_point);
        assert!(store.commit_prepared_host_run(commit).is_err());
        assert_eq!(
            store
                .inspect_v2_aggregate("preparation-1", "run-1", "session-1")
                .unwrap(),
            RuntimeAggregateInspection::EMPTY
        );
        let state = store.agent_os_state();
        assert_eq!(
            state
                .with(|repository| repository.current_global_run_lease())
                .unwrap()
                .unwrap()
                .state(),
            GlobalRunLeaseState::Preparing
        );
        assert!(state
            .with_preparation(|repository| repository.run_preparation("preparation-1"))
            .unwrap()
            .is_some());
    }
}

#[test]
fn in_memory_phase_c_consumes_the_same_preparation_and_promotes_the_lease() {
    let store = InMemoryRuntimeStateStore::new();
    let commit = prepared_commit_fixture_for_state(store.agent_os_state());

    store.commit_prepared_host_run(commit).unwrap();

    let state = store.agent_os_state();
    let lease = state
        .with(|repository| repository.current_global_run_lease())
        .unwrap()
        .unwrap();
    assert_eq!(lease.state(), GlobalRunLeaseState::Active);
    assert_eq!(lease.owner_run_id(), Some("run-1"));
    assert!(state
        .with_preparation(|repository| repository.run_preparation("preparation-1"))
        .unwrap()
        .is_none());
    assert_eq!(store.pending_host_commands().unwrap().len(), 1);
}

#[test]
fn in_memory_phase_c_failures_leave_preparation_and_runtime_aggregate_unchanged() {
    for failure_point in RuntimeAggregateFailurePoint::phase_c_points() {
        let store = InMemoryRuntimeStateStore::new();
        let commit = prepared_commit_fixture_for_state(store.agent_os_state());
        store.inject_failure(failure_point);

        assert!(store.commit_prepared_host_run(commit).is_err());
        assert_eq!(
            store
                .inspect_v2_aggregate("preparation-1", "run-1", "session-1")
                .unwrap(),
            RuntimeAggregateInspection::EMPTY
        );
        let state = store.agent_os_state();
        assert_eq!(
            state
                .with(|repository| repository.current_global_run_lease())
                .unwrap()
                .unwrap()
                .state(),
            GlobalRunLeaseState::Preparing
        );
        assert!(state
            .with_preparation(|repository| repository.run_preparation("preparation-1"))
            .unwrap()
            .is_some());
    }
}

#[test]
fn concurrent_phase_c_commit_has_one_winner() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    let commit = prepared_commit_fixture(&store);
    let first = store.clone();
    let second = store.clone();
    let second_commit = commit.clone();
    let first = std::thread::spawn(move || first.commit_prepared_host_run(commit));
    let second = std::thread::spawn(move || second.commit_prepared_host_run(second_commit));
    let outcomes = [first.join().unwrap(), second.join().unwrap()];

    assert_eq!(outcomes.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(store.pending_host_commands().unwrap().len(), 1);
}

#[test]
fn sqlite_acknowledgement_redacts_payload_but_keeps_identity_after_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let store = SqliteRuntimeStateStore::open(&path).unwrap();
    store
        .insert_worker_and_session(worker_fixture(), session_fixture())
        .unwrap();
    store.transition_and_enqueue(transition_fixture()).unwrap();
    let command: HostCommandEnvelope = wire_fixture("host-command-envelope-v1.json");
    store
        .acknowledge_command(&HostCommandAcknowledgement {
            command_id: command.command_id().to_string(),
            session_handle: command.session_handle().to_string(),
            command_sequence: command.command_sequence(),
            command_envelope_digest: command.command_envelope_digest().to_string(),
            disposition: HostCommandAcknowledgementDisposition::Accepted,
            rejection_code: None,
        })
        .unwrap();
    drop(store);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    let row = reopened
        .host_command(command.command_id())
        .unwrap()
        .unwrap();
    assert!(row.payload().is_none());
    assert_eq!(
        row.command_envelope_digest(),
        command.command_envelope_digest()
    );
    assert_eq!(row.command_sequence(), 1);
}

#[test]
fn event_receipt_and_sequence_effect_follow_the_result_matrix_across_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let store = SqliteRuntimeStateStore::open(&path).unwrap();
    store
        .insert_worker_and_session(worker_fixture(), session_fixture())
        .unwrap();
    let event: LLMEventEnvelope = wire_fixture("llm-event-envelope-v1.json");

    assert!(store
        .apply_event_transactionally(&event, LLMEventSubmissionResult::Backpressure)
        .unwrap()
        .is_none());
    assert_eq!(
        store
            .host_worker("run-1")
            .unwrap()
            .unwrap()
            .expected_event_sequence(),
        1
    );
    let receipt = store
        .apply_event_transactionally(&event, LLMEventSubmissionResult::Accepted)
        .unwrap()
        .unwrap();
    assert_eq!(
        receipt.event_envelope_digest(),
        event.event_envelope_digest()
    );
    assert_eq!(
        store
            .host_worker("run-1")
            .unwrap()
            .unwrap()
            .expected_event_sequence(),
        2
    );
    drop(store);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    assert_eq!(
        reopened
            .event_receipt(event.session_handle(), event.event_sequence())
            .unwrap()
            .unwrap()
            .receipt_digest(),
        receipt.receipt_digest()
    );
}

#[test]
fn execution_event_log_is_a_reopenable_view_of_the_unified_store() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let store = SqliteRuntimeStateStore::open(&path).unwrap();
    let log = ExecutionEventLog::new(store.clone());
    log.append_with_payload("run-1", "run.started", "started");
    drop(log);
    drop(store);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    let events = ExecutionEventLog::new(reopened).replay("run-1", None);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].code(), "run.started");
    assert_eq!(events[0].payload(), "started");
}

#[test]
fn conversation_event_store_is_a_view_of_the_same_in_memory_sqlite_owner() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    let conversation_store = store.conversation_event_store().unwrap();

    assert_eq!(conversation_store.schema_version().unwrap(), 1);
    assert!(conversation_store
        .table_names()
        .unwrap()
        .contains(&"host_workers".to_string()));
    drop(conversation_store);

    store
        .insert_worker_and_session(worker_fixture(), session_fixture())
        .unwrap();
    assert!(store.host_worker("run-1").unwrap().is_some());
}

#[test]
fn terminally_ignored_event_still_consumes_sequence_and_persists_receipt() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    store
        .insert_worker_and_session(worker_fixture(), session_fixture())
        .unwrap();
    let event: LLMEventEnvelope = wire_fixture("llm-event-envelope-v1.json");

    let receipt = store
        .apply_event_transactionally(&event, LLMEventSubmissionResult::TurnTerminal)
        .unwrap()
        .unwrap();
    assert_eq!(
        receipt.disposition(),
        LLMEventReceiptDisposition::TerminallyIgnored
    );
    assert_eq!(
        store
            .host_worker("run-1")
            .unwrap()
            .unwrap()
            .expected_event_sequence(),
        2
    );
}

#[test]
fn old_epoch_recovery_closes_resources_cancels_outbox_and_releases_lease_atomically() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    let commit = prepared_commit_fixture(&store);
    let command_id = commit.first_command.command_id().to_string();
    store.commit_prepared_host_run(commit).unwrap();

    let recovered = store
        .recover_run_for_epoch("run-1", "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        .unwrap();

    assert!(matches!(
        recovered.logical_outcome(),
        LogicalRunOutcome::Interrupted { code } if code == "host_epoch_ended"
    ));
    assert_eq!(
        recovered.resource_lifecycle(),
        &ResourceLifecycle::Closed {
            disposition: HostSessionCloseDisposition::EpochEnded,
        }
    );
    assert!(recovered.is_fully_terminal());
    assert_eq!(
        store
            .host_session("session-1")
            .unwrap()
            .unwrap()
            .resource_lifecycle(),
        &ResourceLifecycle::Closed {
            disposition: HostSessionCloseDisposition::EpochEnded,
        }
    );
    let cancelled = store.host_command(&command_id).unwrap().unwrap();
    assert_eq!(cancelled.status(), HostCommandOutboxStatus::Cancelled);
    assert!(cancelled.payload().is_none());
    assert!(store.pending_host_commands().unwrap().is_empty());
    assert!(store
        .agent_os_state()
        .with(|repository| repository.current_global_run_lease())
        .unwrap()
        .is_none());
    assert!(ExecutionEventLog::new(store)
        .replay("run-1", None)
        .iter()
        .any(|event| event.code() == "run.interrupted"));
}

#[test]
fn lifecycle_watchdogs_preserve_logical_outcome_and_schedule_at_most_one_close() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    let worker = worker_fixture()
        .with_execution_phase(None)
        .with_logical_outcome(LogicalRunOutcome::Succeeded {
            finish_reason: "stop".into(),
        })
        .with_resource_lifecycle(ResourceLifecycle::AwaitingSessionClosed)
        .with_watchdog(
            Some(HostWatchdogKind::SessionClose),
            Some("close-command".into()),
            Some(5),
        );
    let session =
        session_fixture().with_resource_lifecycle(ResourceLifecycle::AwaitingSessionClosed);
    store.insert_worker_and_session(worker, session).unwrap();

    assert_eq!(store.fail_expired_host_watchdogs(6).unwrap().len(), 1);
    assert!(matches!(
        store.host_worker("run-1").unwrap().unwrap().logical_outcome(),
        LogicalRunOutcome::Succeeded { finish_reason } if finish_reason == "stop"
    ));
    assert!(matches!(
        store
            .host_worker("run-1")
            .unwrap()
            .unwrap()
            .resource_lifecycle(),
        ResourceLifecycle::Quarantined { code } if code == "llm.session.close_timeout"
    ));
    assert!(store.fail_expired_host_watchdogs(7).unwrap().is_empty());
    assert!(store.pending_host_commands().unwrap().is_empty());
}

#[test]
fn exact_session_closed_is_the_only_normal_lease_release_gate() {
    let store = SqliteRuntimeStateStore::open_in_memory().unwrap();
    let commit = prepared_commit_fixture(&store);
    store.commit_prepared_host_run(commit).unwrap();
    let start = store.pending_host_commands().unwrap()[0]
        .payload()
        .unwrap()
        .clone();
    acknowledge(
        &store,
        &start,
        HostCommandAcknowledgementDisposition::Accepted,
    );
    let service = HostLLMWorkerService::new(Arc::new(store.clone()));
    assert_eq!(
        service
            .submit_event(&host_event(
                1,
                "started",
                LLMEventKind::GenerationStarted,
                LLMEventPayload {
                    command_id: Some(start.command_id().into()),
                    opaque_operation_id: Some("operation-1".into()),
                    ..Default::default()
                },
                Some("turn-1"),
            ))
            .unwrap(),
        LLMEventSubmissionResult::Accepted
    );
    assert_eq!(
        service
            .submit_event(&host_event(
                2,
                "completed",
                LLMEventKind::GenerationCompleted,
                LLMEventPayload {
                    completion: Some(LLMBackendCompletionWire {
                        outcome: "final_response".into(),
                        ordered_call_ids: vec![],
                        finish_reason: "stop".into(),
                    }),
                    ..Default::default()
                },
                Some("turn-1"),
            ))
            .unwrap(),
        LLMEventSubmissionResult::Accepted
    );
    assert_eq!(
        store
            .agent_os_state()
            .with(|repository| repository.current_global_run_lease())
            .unwrap()
            .unwrap()
            .state(),
        GlobalRunLeaseState::Releasing
    );

    let close = store.pending_host_commands().unwrap()[0]
        .payload()
        .unwrap()
        .clone();
    acknowledge(
        &store,
        &close,
        HostCommandAcknowledgementDisposition::Accepted,
    );
    assert_eq!(
        service
            .submit_event(&host_event(
                3,
                "closed",
                LLMEventKind::SessionClosed,
                LLMEventPayload {
                    command_id: Some(close.command_id().into()),
                    close_disposition: Some("closed".into()),
                    ..Default::default()
                },
                None,
            ))
            .unwrap(),
        LLMEventSubmissionResult::Accepted
    );

    assert!(store
        .host_worker("run-1")
        .unwrap()
        .unwrap()
        .is_fully_terminal());
    assert!(store
        .agent_os_state()
        .with(|repository| repository.current_global_run_lease())
        .unwrap()
        .is_none());
}

fn worker_fixture() -> HostWorkerRecord {
    HostWorkerRecord::new(
        "run-1",
        "session-1",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    )
    .with_execution_phase(Some(HostExecutionPhase::AwaitingStartCommandAck))
}

fn session_fixture() -> HostSessionRecord {
    HostSessionRecord::new(
        "run-1",
        "session-1",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "binding-1",
        5,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
}

fn transition_fixture() -> RuntimeTransition {
    let command: HostCommandEnvelope = wire_fixture("host-command-envelope-v1.json");
    RuntimeTransition::new(
        0,
        worker_fixture()
            .with_revision(1)
            .with_execution_phase(Some(HostExecutionPhase::AwaitingGenerationStarted)),
        command,
    )
}

fn acknowledge(
    store: &SqliteRuntimeStateStore,
    command: &HostCommandEnvelope,
    disposition: HostCommandAcknowledgementDisposition,
) {
    store
        .acknowledge_command(&HostCommandAcknowledgement {
            command_id: command.command_id().into(),
            session_handle: command.session_handle().into(),
            command_sequence: command.command_sequence(),
            command_envelope_digest: command.command_envelope_digest().into(),
            disposition,
            rejection_code: None,
        })
        .unwrap();
}

fn host_event(
    sequence: u64,
    id: &str,
    kind: LLMEventKind,
    payload: LLMEventPayload,
    generation_turn_id: Option<&str>,
) -> LLMEventEnvelope {
    let mut event = LLMEventEnvelope {
        schema_version: 1,
        event_id: id.into(),
        run_id: "run-1".into(),
        session_handle: "session-1".into(),
        host_process_epoch: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into(),
        generation_turn_id: generation_turn_id.map(str::to_string),
        event_sequence: sequence,
        kind,
        payload,
        event_envelope_digest: String::new(),
    };
    event.event_envelope_digest = event.expected_digest().unwrap();
    event
}

fn prepared_commit_fixture(store: &SqliteRuntimeStateStore) -> PreparedHostRunCommit {
    prepared_commit_fixture_for_state(store.agent_os_state())
}

fn prepared_commit_fixture_for_state(
    agent_os_state: SharedAgentOSStateStore,
) -> PreparedHostRunCommit {
    let service = RunPreparationService::with_authoritative_preview(
        agent_os_state,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        Arc::new(RunSnapshotService::fixture_with_host_slot_v2()),
    );
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame-1"),
        SessionId("conversation-1".into()),
        EntryId("branch-1".into()),
        EntryId("turn-1".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(
            EntryId("turn-1".into()),
            "hello",
        )],
        vec![],
        ConversationLineage::new(EntryId("branch-1".into()), None, None),
    );
    let preview = service
        .preview_authoritative(
            "preview-1",
            "preparation-1",
            "run-1",
            StartRunRequest::new("profile_1", AgentProfileVersion::new(1), "hello", frame_ref),
            &frame,
            0,
        )
        .unwrap();
    let registration = PreparedSessionRegistration::new(
        "registration-1",
        preview.preparation_id(),
        preview.proposed_run_id(),
        "session-1",
        "snapshot-1",
        preview.host_process_epoch(),
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "",
    )
    .with_binding_identity("binding-1", 5)
    .with_computed_digest()
    .unwrap();
    service
        .register_prepared_session(preview.token(), registration, 60_000)
        .unwrap();

    PreparedHostRunCommit {
        preparation_id: "preparation-1".into(),
        consumed_token_digest: preview.token_digest().into(),
        lease_generation: preview.lease_generation(),
        snapshot_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc".into(),
        snapshot_json: r#"{"schema_version":2,"run_id":"run-1"}"#.into(),
        initial_event_code: "run.started".into(),
        initial_event_payload: "run.started".into(),
        worker: worker_fixture().with_generation_turn_id(Some("turn-1".into())),
        session: session_fixture(),
        first_command: wire_fixture("host-command-envelope-v1.json"),
    }
}

fn wire_fixture<T: DeserializeOwned>(name: &str) -> T {
    let value: Value =
        serde_json::from_slice(&fs::read(contracts_root().join(name)).unwrap()).unwrap();
    serde_json::from_value(value["wire"].clone()).unwrap()
}

fn contracts_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("contracts/canonical-digest-v1/fixtures")
}
