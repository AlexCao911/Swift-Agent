use local_ios_agent_runtime::llm_contracts::{
    HostAttestation, PreparationAbortReason, PreparationBinding, PreparedSessionClosedReceipt,
    PreparedSessionRegistration, RunPreparationRequest, RunPreparationState,
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
    let service = RunPreparationService::new(state, "epoch-1");
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

    let wrong = PreparedSessionClosedReceipt::from_cleanup(
        cleanup,
        "different-handle",
        "closed",
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
        "closed",
        "closed-receipt-digest-1",
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
fn sqlite_preparation_record_survives_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let service = RunPreparationService::new(
        SharedAgentOSStateStore::new(SqliteAgentOSStateStore::open(&path).unwrap()),
        "epoch-1",
    );
    let preview = service.preview_run(request(), 0).unwrap();
    drop(service);

    let reopened = RunPreparationService::new(
        SharedAgentOSStateStore::new(SqliteAgentOSStateStore::open(&path).unwrap()),
        "epoch-1",
    );
    let record = reopened
        .preparation(preview.preparation_id())
        .unwrap()
        .unwrap();
    assert_eq!(record.preview(), &preview);
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
