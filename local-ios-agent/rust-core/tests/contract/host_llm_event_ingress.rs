use std::sync::Arc;

use local_ios_agent_runtime::execution::{HostLLMWorkerService, HostLLMWorkerServiceConfig};
use local_ios_agent_runtime::llm_contracts::{
    HostExecutionPhase, HostSessionRecord, HostWorkerRecord, LLMBackendCompletionWire,
    LLMEventEnvelope, LLMEventKind, LLMEventPayload, LLMEventReceiptDisposition,
    LLMEventSubmissionResult, LogicalRunOutcome, ResourceLifecycle, SequenceEffect,
};
use local_ios_agent_runtime::storage::{
    RuntimeAggregateFailurePoint, SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};

const EPOCH: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[test]
fn result_matrix_consumes_only_durable_receipt_results() {
    assert_eq!(
        LLMEventSubmissionResult::Accepted.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert_eq!(
        LLMEventSubmissionResult::TurnTerminal.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert_eq!(
        LLMEventSubmissionResult::GenerationTerminal.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert_eq!(
        LLMEventSubmissionResult::PayloadTooLarge.sequence_effect(),
        SequenceEffect::ConsumeNew
    );
    assert_eq!(
        LLMEventSubmissionResult::Duplicate.sequence_effect(),
        SequenceEffect::AlreadyConsumed
    );
    assert_eq!(
        LLMEventSubmissionResult::SequenceConflict.sequence_effect(),
        SequenceEffect::AlreadyConsumed
    );
    for result in [
        LLMEventSubmissionResult::Backpressure,
        LLMEventSubmissionResult::StaleSession,
        LLMEventSubmissionResult::ClosedSession,
        LLMEventSubmissionResult::SequenceGap,
        LLMEventSubmissionResult::IdentityConflict,
        LLMEventSubmissionResult::InvalidEnvelope,
    ] {
        assert_eq!(result.sequence_effect(), SequenceEffect::DoNotConsume);
        assert_eq!(
            result.retry_same_envelope(),
            result == LLMEventSubmissionResult::Backpressure
        );
    }
}

#[test]
fn terminally_ignored_event_consumes_n_so_close_at_n_plus_one_is_valid() {
    let store = Arc::new(SqliteRuntimeStateStore::open_in_memory().unwrap());
    let worker = worker_fixture()
        .with_expected_event_sequence(5)
        .with_execution_phase(None)
        .with_generation_turn_id(Some("turn-1".into()))
        .with_logical_outcome(LogicalRunOutcome::Succeeded {
            finish_reason: "stop".into(),
        })
        .with_resource_lifecycle(ResourceLifecycle::AwaitingSessionClosed);
    let session =
        session_fixture().with_resource_lifecycle(ResourceLifecycle::AwaitingSessionClosed);
    store.insert_worker_and_session(worker, session).unwrap();
    let service = HostLLMWorkerService::new(store.clone());

    let late = event(
        5,
        "late",
        LLMEventKind::TextDelta,
        text_payload("late"),
        Some("turn-1"),
    );
    assert_eq!(
        service.submit_event(&late).unwrap(),
        LLMEventSubmissionResult::GenerationTerminal
    );
    assert_eq!(
        store
            .event_receipt("session-1", 5)
            .unwrap()
            .unwrap()
            .disposition(),
        LLMEventReceiptDisposition::TerminallyIgnored
    );

    let close = event(
        6,
        "close",
        LLMEventKind::SessionClosed,
        LLMEventPayload {
            command_id: Some("close-command".into()),
            close_disposition: Some("closed".into()),
            ..Default::default()
        },
        None,
    );
    assert_eq!(
        service.submit_event(&close).unwrap(),
        LLMEventSubmissionResult::Accepted
    );
    assert_eq!(
        store
            .event_receipt("session-1", 6)
            .unwrap()
            .unwrap()
            .disposition(),
        LLMEventReceiptDisposition::Closed
    );
}

#[test]
fn conflict_precedes_terminal_lifecycle_filtering() {
    let store = Arc::new(SqliteRuntimeStateStore::open_in_memory().unwrap());
    store
        .insert_worker_and_session(consuming_worker(), session_fixture())
        .unwrap();
    let service = HostLLMWorkerService::new(store);
    let terminal = event(
        1,
        "terminal",
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
    );
    assert_eq!(
        service.submit_event(&terminal).unwrap(),
        LLMEventSubmissionResult::Accepted
    );

    let conflict = event(
        1,
        "other-id",
        LLMEventKind::TextDelta,
        text_payload("late"),
        Some("turn-1"),
    );
    assert_eq!(
        service.submit_event(&conflict).unwrap(),
        LLMEventSubmissionResult::SequenceConflict
    );
}

#[test]
fn backpressure_does_not_consume_or_persist_and_low_water_emits_one_command() {
    let store = Arc::new(SqliteRuntimeStateStore::open_in_memory().unwrap());
    store
        .insert_worker_and_session(consuming_worker(), session_fixture())
        .unwrap();
    let service = HostLLMWorkerService::new(store.clone());

    for sequence in 1..=256 {
        assert_eq!(
            service
                .submit_event(&event(
                    sequence,
                    &format!("event-{sequence}"),
                    LLMEventKind::TextDelta,
                    text_payload("x"),
                    Some("turn-1"),
                ))
                .unwrap(),
            LLMEventSubmissionResult::Accepted
        );
    }
    let blocked = event(
        257,
        "blocked",
        LLMEventKind::TextDelta,
        text_payload("x"),
        Some("turn-1"),
    );
    assert_eq!(
        service.submit_event(&blocked).unwrap(),
        LLMEventSubmissionResult::Backpressure
    );
    assert!(store.event_receipt("session-1", 257).unwrap().is_none());
    assert_eq!(
        store
            .host_worker("run-1")
            .unwrap()
            .unwrap()
            .expected_event_sequence(),
        257
    );

    assert_eq!(service.drain_inbound_events(129).unwrap().len(), 129);
    assert_eq!(store.pending_host_commands().unwrap().len(), 1);
    assert_eq!(
        service.submit_event(&blocked).unwrap(),
        LLMEventSubmissionResult::Accepted
    );
}

#[test]
fn a_single_oversize_event_consumes_a_terminal_failure_receipt_and_closes() {
    let store = Arc::new(SqliteRuntimeStateStore::open_in_memory().unwrap());
    store
        .insert_worker_and_session(consuming_worker(), session_fixture())
        .unwrap();
    let service = HostLLMWorkerService::new(store.clone());
    let oversized = event(
        1,
        "oversized",
        LLMEventKind::TextDelta,
        text_payload(&"x".repeat(2 * 1024 * 1024)),
        Some("turn-1"),
    );

    assert_eq!(
        service.submit_event(&oversized).unwrap(),
        LLMEventSubmissionResult::PayloadTooLarge
    );
    assert_eq!(
        store
            .event_receipt("session-1", 1)
            .unwrap()
            .unwrap()
            .disposition(),
        LLMEventReceiptDisposition::TerminalFailure
    );
    assert!(matches!(
        store.host_worker("run-1").unwrap().unwrap().logical_outcome(),
        LogicalRunOutcome::Failed { code } if code == "llm.event.payload_too_large"
    ));
    assert_eq!(store.pending_host_commands().unwrap().len(), 1);
}

#[test]
fn every_event_apply_failure_rolls_back_receipt_sequence_queue_and_accumulator() {
    for point in RuntimeAggregateFailurePoint::event_points() {
        let store = Arc::new(SqliteRuntimeStateStore::open_in_memory().unwrap());
        store
            .insert_worker_and_session(consuming_worker(), session_fixture())
            .unwrap();
        store.inject_failure(point);
        let service = HostLLMWorkerService::new(store.clone());

        assert!(service
            .submit_event(&event(
                1,
                "event-1",
                LLMEventKind::TextDelta,
                text_payload("hello"),
                Some("turn-1"),
            ))
            .is_err());
        assert_eq!(
            store
                .host_worker("run-1")
                .unwrap()
                .unwrap()
                .expected_event_sequence(),
            1
        );
        assert!(store.event_receipt("session-1", 1).unwrap().is_none());
        assert_eq!(store.event_queue_usage("session-1").unwrap().event_count, 0);
        assert!(store
            .turn_accumulator_events("session-1", "turn-1")
            .unwrap()
            .is_empty());
    }
}

#[test]
fn exact_duplicate_replays_after_reopen_without_duplicate_accumulator_content() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let store = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    store
        .insert_worker_and_session(consuming_worker(), session_fixture())
        .unwrap();
    let accepted = event(
        1,
        "event-1",
        LLMEventKind::TextDelta,
        text_payload("hello"),
        Some("turn-1"),
    );
    assert_eq!(
        HostLLMWorkerService::new(store.clone())
            .submit_event(&accepted)
            .unwrap(),
        LLMEventSubmissionResult::Accepted
    );
    drop(store);

    let reopened = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    let service = HostLLMWorkerService::new(reopened.clone());
    assert_eq!(
        service.submit_event(&accepted).unwrap(),
        LLMEventSubmissionResult::Duplicate
    );
    assert_eq!(
        reopened
            .turn_accumulator_events("session-1", "turn-1")
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn configured_limits_are_not_allowed_to_weaken_product_limits() {
    let limits = HostLLMWorkerServiceConfig::default();
    assert_eq!(limits.max_events, 256);
    assert_eq!(limits.max_bytes, 2 * 1024 * 1024);
    assert_eq!(limits.low_water_events, 128);
    assert_eq!(limits.low_water_bytes, 1024 * 1024);
}

fn consuming_worker() -> HostWorkerRecord {
    worker_fixture()
        .with_execution_phase(Some(HostExecutionPhase::ConsumingLlmTurn))
        .with_generation_turn_id(Some("turn-1".into()))
        .with_resource_lifecycle(ResourceLifecycle::Generating)
}

fn worker_fixture() -> HostWorkerRecord {
    HostWorkerRecord::new("run-1", "session-1", EPOCH)
}

fn session_fixture() -> HostSessionRecord {
    HostSessionRecord::new(
        "run-1",
        "session-1",
        EPOCH,
        "binding-1",
        1,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
}

fn text_payload(text: &str) -> LLMEventPayload {
    LLMEventPayload {
        text: Some(text.into()),
        ..Default::default()
    }
}

fn event(
    sequence: u64,
    id: &str,
    kind: LLMEventKind,
    payload: LLMEventPayload,
    turn: Option<&str>,
) -> LLMEventEnvelope {
    let mut event = LLMEventEnvelope {
        schema_version: 1,
        event_id: id.into(),
        run_id: "run-1".into(),
        session_handle: "session-1".into(),
        host_process_epoch: EPOCH.into(),
        generation_turn_id: turn.map(str::to_string),
        event_sequence: sequence,
        kind,
        payload,
        event_envelope_digest: String::new(),
    };
    event.event_envelope_digest = event.expected_digest().unwrap();
    event
}
