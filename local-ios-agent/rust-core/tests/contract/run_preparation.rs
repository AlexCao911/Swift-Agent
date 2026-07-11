use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::llm_contracts::{
    HostAttestation, PreparationAbortReason, PreparationBinding,
    PreparedSessionCleanupAcknowledgement, PreparedSessionCloseDisposition,
    PreparedSessionClosedReceipt, PreparedSessionRegistration, RunPreparationRequest,
    RunPreparationState,
};
use local_ios_agent_runtime::run_snapshot::RunPreparationService;
use local_ios_agent_runtime::storage::agent_os_state::{
    SharedAgentOSStateStore, SqliteAgentOSStateStore,
};

const MINUTE: u64 = 60_000;

fn request() -> RunPreparationRequest {
    RunPreparationRequest::new(
        "preview-operation-1",
        "preparation-1",
        "proposed-run-1",
        PreparationBinding::new(
            "profile-1",
            4,
            "frame-digest",
            "plan-digest",
            "requirements-digest",
            "tool-schema-digest",
            "input-1",
            "model-input-digest",
            "source-revisions-digest",
            "disclosure-digest",
        ),
    )
}

fn registration(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedSessionRegistration {
    PreparedSessionRegistration::new(
        "registration-operation-1",
        preview.preparation_id(),
        preview.proposed_run_id(),
        "session-handle-1",
        "swift-snapshot-1",
        "epoch-1",
        "binding-hash-1",
        "registration-digest-1",
    )
}

#[test]
fn preview_freezes_binding_and_renewal_rotates_with_total_ceiling() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    assert_eq!(preview.expiration_millis(), 5 * MINUTE);
    assert_eq!(preview.total_deadline_millis(), 30 * MINUTE);
    assert_eq!(preview.binding(), request().binding());

    let renewed = service
        .renew_preparation(
            preview.token(),
            preview.binding_digest(),
            "renewal-1",
            4 * MINUTE,
        )
        .unwrap();
    assert_ne!(renewed.token(), preview.token());
    assert_eq!(renewed.expiration_millis(), 9 * MINUTE);
    assert_eq!(
        state
            .with(|store| store.current_global_run_lease())
            .unwrap()
            .unwrap()
            .preparation_expiration(),
        Some(renewed.expiration_millis())
    );
    assert_eq!(
        service
            .renew_preparation(
                preview.token(),
                preview.binding_digest(),
                "renewal-1",
                4 * MINUTE,
            )
            .unwrap(),
        renewed
    );
    assert_eq!(
        service
            .renew_preparation(
                preview.token(),
                preview.binding_digest(),
                "different-replay",
                4 * MINUTE,
            )
            .unwrap_err()
            .code(),
        "preparation.token_stale"
    );

    let mut current = renewed;
    for (index, minute) in [8, 12, 16, 20, 24, 28].into_iter().enumerate() {
        current = service
            .renew_preparation(
                current.token(),
                current.binding_digest(),
                &format!("renewal-{}", index + 2),
                minute * MINUTE,
            )
            .unwrap();
    }
    assert_eq!(current.expiration_millis(), 30 * MINUTE);
    assert_eq!(
        service
            .renew_preparation(
                current.token(),
                current.binding_digest(),
                "renewal-over-ceiling",
                30 * MINUTE,
            )
            .unwrap_err()
            .code(),
        "preparation.token_expired"
    );
}

#[test]
fn registration_is_exact_and_phase_one_commit_begins_one_cleanup() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    let registered = service
        .register_prepared_session(preview.token(), registration(&preview), MINUTE)
        .unwrap();
    assert_eq!(registered.state(), RunPreparationState::Registered);
    assert_eq!(
        service
            .register_prepared_session(preview.token(), registration(&preview), MINUTE)
            .unwrap(),
        registered
    );

    let conflict = PreparedSessionRegistration::new(
        "registration-operation-1",
        preview.preparation_id(),
        preview.proposed_run_id(),
        "different-handle",
        "swift-snapshot-1",
        "epoch-1",
        "binding-hash-1",
        "registration-digest-1",
    );
    assert_eq!(
        service
            .register_prepared_session(preview.token(), conflict, MINUTE)
            .unwrap_err()
            .code(),
        "preparation.registration_conflict"
    );

    let attestation = HostAttestation::from_registration(
        registration(&preview),
        preview.binding_digest(),
        "egress-attestation-digest",
        2 * MINUTE,
    );
    assert_eq!(
        service
            .commit_start(preview.token(), attestation, 90_000)
            .unwrap_err()
            .code(),
        "execution.host_slot_v2_not_runnable"
    );
    let record = service
        .preparation(preview.preparation_id())
        .unwrap()
        .unwrap();
    assert_eq!(record.state(), RunPreparationState::Aborting);
    let cleanup = record.cleanup().unwrap().clone();

    let replay = service
        .begin_abort_preparation(
            preview.preparation_id(),
            Some(preview.token()),
            "abort-replay",
            PreparationAbortReason::CommitRejected,
        )
        .unwrap()
        .cleanup()
        .unwrap()
        .clone();
    assert_eq!(replay, cleanup);
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_some());
}

#[test]
fn exact_prepared_close_receipt_is_required_to_release() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    service
        .register_prepared_session(preview.token(), registration(&preview), MINUTE)
        .unwrap();
    let aborted = service
        .begin_abort_preparation(
            preview.preparation_id(),
            Some(preview.token()),
            "abort-1",
            PreparationAbortReason::UserDenied,
        )
        .unwrap();
    let cleanup = aborted.cleanup().unwrap();

    let premature = PreparedSessionClosedReceipt::from_cleanup(
        cleanup,
        cleanup.session_handle(),
        PreparedSessionCloseDisposition::Closed,
        close_receipt_digest(cleanup, "closed"),
    );
    assert_eq!(
        service
            .confirm_prepared_session_closed(premature)
            .unwrap_err()
            .code(),
        "preparation.cleanup_not_acknowledged"
    );

    let acknowledgement = PreparedSessionCleanupAcknowledgement::from_cleanup(cleanup);
    service
        .ack_prepared_session_cleanup(acknowledgement.clone())
        .unwrap();
    service
        .ack_prepared_session_cleanup(acknowledgement)
        .unwrap();

    let wrong = PreparedSessionClosedReceipt::from_cleanup(
        cleanup,
        "different-handle",
        PreparedSessionCloseDisposition::Closed,
        "closed-receipt-digest-1",
    );
    assert_eq!(
        service
            .confirm_prepared_session_closed(wrong)
            .unwrap_err()
            .code(),
        "preparation.close_receipt_mismatch"
    );
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_some());

    let receipt = PreparedSessionClosedReceipt::from_cleanup(
        cleanup,
        cleanup.session_handle(),
        PreparedSessionCloseDisposition::Closed,
        close_receipt_digest(cleanup, "closed"),
    );
    let closed = service
        .confirm_prepared_session_closed(receipt.clone())
        .unwrap();
    assert_eq!(closed.state(), RunPreparationState::Closed);
    assert_eq!(
        service.confirm_prepared_session_closed(receipt).unwrap(),
        closed
    );
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_none());
}

#[test]
fn external_close_receipt_rejects_epoch_ended_disposition() {
    let json = r#"{
      "cleanup_command_id":"cleanup-1",
      "preparation_id":"preparation-1",
      "proposed_run_id":"run-1",
      "session_handle":"session-1",
      "host_process_epoch":"epoch-1",
      "preparation_cleanup_sequence":1,
      "close_disposition":"epoch_ended",
      "receipt_digest":"digest-1"
    }"#;
    assert!(serde_json::from_str::<PreparedSessionClosedReceipt>(json).is_err());
}

#[test]
fn sqlite_cleanup_outbox_requires_ack_before_atomic_close_and_release() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let state = SharedAgentOSStateStore::new(SqliteAgentOSStateStore::open(&path).unwrap());
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    service
        .register_prepared_session(preview.token(), registration(&preview), MINUTE)
        .unwrap();
    let aborted = service
        .begin_abort_preparation(
            preview.preparation_id(),
            Some(preview.token()),
            "sqlite-abort",
            PreparationAbortReason::UserDenied,
        )
        .unwrap();
    let cleanup = aborted.cleanup().unwrap();
    service
        .ack_prepared_session_cleanup(PreparedSessionCleanupAcknowledgement::from_cleanup(cleanup))
        .unwrap();
    let receipt = PreparedSessionClosedReceipt::from_cleanup(
        cleanup,
        cleanup.session_handle(),
        PreparedSessionCloseDisposition::AlreadyClosed,
        close_receipt_digest(cleanup, "already_closed"),
    );
    let closed = service.confirm_prepared_session_closed(receipt).unwrap();
    assert_eq!(closed.state(), RunPreparationState::Closed);
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_none());
}

fn close_receipt_digest(
    cleanup: &local_ios_agent_runtime::llm_contracts::PreparedSessionCleanupEnvelope,
    disposition: &str,
) -> String {
    #[derive(serde::Serialize)]
    struct Document<'a> {
        cleanup_command_id: &'a str,
        preparation_id: &'a str,
        proposed_run_id: &'a str,
        session_handle: &'a str,
        host_process_epoch: &'a str,
        cleanup_sequence: u64,
        prepared_session_registration_digest: &'a str,
        cleanup_command_digest: &'a str,
        close_disposition: &'a str,
    }
    CanonicalDigestV1::digest(
        "prepared-session-closed-receipt:v1",
        &Document {
            cleanup_command_id: cleanup.cleanup_command_id(),
            preparation_id: cleanup.preparation_id(),
            proposed_run_id: cleanup.proposed_run_id(),
            session_handle: cleanup.session_handle(),
            host_process_epoch: cleanup.host_process_epoch(),
            cleanup_sequence: cleanup.preparation_cleanup_sequence(),
            prepared_session_registration_digest: cleanup.prepared_session_registration_digest(),
            cleanup_command_digest: cleanup.cleanup_command_digest(),
            close_disposition: disposition,
        },
    )
    .unwrap()
    .as_str()
    .to_string()
}

#[test]
fn abort_before_registration_releases_immediately_and_old_epoch_recovers_registered_session() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    let released = service
        .begin_abort_preparation(
            preview.preparation_id(),
            Some(preview.token()),
            "abort-no-session",
            PreparationAbortReason::PreparationFailed,
        )
        .unwrap();
    assert!(released.cleanup().is_none());
    assert_eq!(released.state(), RunPreparationState::Closed);
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_none());

    let second_request = RunPreparationRequest::new(
        "preview-operation-2",
        "preparation-2",
        "proposed-run-2",
        request().binding().clone(),
    );
    let second = service.preview_run(second_request, MINUTE).unwrap();
    service
        .register_prepared_session(second.token(), registration_for(&second), 2 * MINUTE)
        .unwrap();
    let recovered = service.recover_old_epoch("epoch-2").unwrap();
    assert_eq!(recovered, vec!["preparation-2".to_string()]);
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_none());
}

fn registration_for(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedSessionRegistration {
    PreparedSessionRegistration::new(
        "registration-operation-2",
        preview.preparation_id(),
        preview.proposed_run_id(),
        "session-handle-2",
        "swift-snapshot-2",
        "epoch-1",
        "binding-hash-2",
        "registration-digest-2",
    )
}

#[test]
fn sqlite_preparation_record_survives_reopen_without_bearer() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let state = SharedAgentOSStateStore::new(SqliteAgentOSStateStore::open(&path).unwrap());
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    let renewed = service
        .renew_preparation(
            preview.token(),
            preview.binding_digest(),
            "sqlite-renewal",
            4 * MINUTE,
        )
        .unwrap();
    assert_eq!(
        state
            .with(|store| store.current_global_run_lease())
            .unwrap()
            .unwrap()
            .preparation_expiration(),
        Some(renewed.expiration_millis())
    );
    drop(service);
    drop(state);

    let reopened = RunPreparationService::new(
        SharedAgentOSStateStore::new(SqliteAgentOSStateStore::open(&path).unwrap()),
        "epoch-1",
    );
    let record = reopened
        .preparation(renewed.preparation_id())
        .unwrap()
        .unwrap();
    assert!(record.preview().token().is_empty());
    assert_eq!(record.preview().token_digest(), renewed.token_digest());
    assert_eq!(record.preview().binding(), renewed.binding());
    assert_eq!(record.preview().binding_digest(), renewed.binding_digest());
    assert_eq!(
        record.preview().lease_generation(),
        renewed.lease_generation()
    );
}

#[test]
fn token_expiry_after_registration_enters_the_same_cleanup_path() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = RunPreparationService::new(state.clone(), "epoch-1");
    let preview = service.preview_run(request(), 0).unwrap();
    service
        .register_prepared_session(preview.token(), registration(&preview), MINUTE)
        .unwrap();

    assert_eq!(
        service
            .renew_preparation(
                preview.token(),
                preview.binding_digest(),
                "renew-after-expiry",
                preview.expiration_millis(),
            )
            .unwrap_err()
            .code(),
        "preparation.token_expired"
    );
    let record = service
        .preparation(preview.preparation_id())
        .unwrap()
        .unwrap();
    assert_eq!(record.state(), RunPreparationState::Aborting);
    assert_eq!(
        record.cleanup().unwrap().reason(),
        PreparationAbortReason::TokenExpired
    );
    assert!(state
        .with(|store| store.current_global_run_lease())
        .unwrap()
        .is_some());
}
