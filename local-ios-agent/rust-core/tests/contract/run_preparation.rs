use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::conversation::{
    ConversationFrameId, ConversationFrameMessage, ConversationLineage, ConversationRunFrame,
    ConversationRunFrameRef,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::llm_contracts::{
    HostAttestation, HostBindingActivationConfirmation, HostBindingCommit,
    HostBindingStagingReceipt, HostBindingTuple, LLMInputModality, PreparationAbortReason,
    PreparedCapabilityAttestation, PreparedSessionCleanupAcknowledgement,
    PreparedSessionCloseDisposition, PreparedSessionClosedReceipt, PreparedSessionRegistration,
    PreparedStartValidator, ProfilePublishPreparation, RunPreparationState,
};
use local_ios_agent_runtime::run_snapshot::{
    RunPreparationService, RunSnapshotService, StartRunRequest,
};
use local_ios_agent_runtime::storage::agent_os_state::{
    SharedAgentOSStateStore, SqliteAgentOSStateStore,
};
use local_ios_agent_runtime::user_customization::AgentProfileVersion;

const MINUTE: u64 = 60_000;
const BINDING_HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const RESOLVED_PARAMETERS_DIGEST: &str =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const CAPABILITY_PLACEHOLDER_DIGEST: &str =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const OPAQUE_SUBJECT_DIGEST: &str =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
const ALTERNATE_OPAQUE_SUBJECT_DIGEST: &str =
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

#[test]
fn authoritative_preview_derives_model_input_and_source_digests_from_rust_sources() {
    let snapshot = std::sync::Arc::new(RunSnapshotService::fixture_with_host_slot_v2());
    let first_service = RunPreparationService::with_authoritative_preview(
        SharedAgentOSStateStore::in_memory(),
        "epoch-authoritative-1",
        snapshot.clone(),
    );
    let second_service = RunPreparationService::with_authoritative_preview(
        SharedAgentOSStateStore::in_memory(),
        "epoch-authoritative-2",
        snapshot,
    );
    let first_frame = authoritative_frame("first input");
    let second_frame = authoritative_frame("changed input");
    let first = first_service
        .preview_authoritative(
            "authoritative-preview-1",
            "authoritative-preparation-1",
            "authoritative-run-1",
            authoritative_start(first_frame.frame_ref().clone(), "first input"),
            &first_frame,
            0,
        )
        .unwrap();
    let second = second_service
        .preview_authoritative(
            "authoritative-preview-2",
            "authoritative-preparation-2",
            "authoritative-run-2",
            authoritative_start(second_frame.frame_ref().clone(), "changed input"),
            &second_frame,
            0,
        )
        .unwrap();

    assert_ne!(
        first.binding().conversation_frame_digest(),
        second.binding().conversation_frame_digest()
    );
    assert_ne!(
        first.binding().model_input_digest(),
        second.binding().model_input_digest()
    );
    let bytes = first_service
        .frozen_model_input(first.binding().model_input_id())
        .unwrap()
        .unwrap();
    let document: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        CanonicalDigestV1::digest("agent-input:v1", &document)
            .unwrap()
            .as_str(),
        first.binding().model_input_digest()
    );
}

fn authoritative_start(frame_ref: ConversationRunFrameRef, intent: &str) -> StartRunRequest {
    StartRunRequest::new("profile_1", AgentProfileVersion::new(1), intent, frame_ref)
}

fn authoritative_frame(text: &str) -> ConversationRunFrame {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame-authoritative"),
        SessionId("session-authoritative".to_string()),
        EntryId("branch-authoritative".to_string()),
        EntryId("turn-authoritative".to_string()),
    );
    ConversationRunFrame::new(
        frame_ref,
        None,
        vec![ConversationFrameMessage::user(
            EntryId("turn-authoritative".to_string()),
            text,
        )],
        vec![],
        ConversationLineage::new(EntryId("branch-authoritative".to_string()), None, None),
    )
}

fn test_service(state: SharedAgentOSStateStore, epoch: &str) -> RunPreparationService {
    RunPreparationService::with_authoritative_preview(
        state,
        epoch,
        std::sync::Arc::new(RunSnapshotService::fixture_with_host_slot_v2()),
    )
}

fn preview_fixture(
    service: &RunPreparationService,
    suffix: &str,
    now_millis: u64,
) -> local_ios_agent_runtime::llm_contracts::RunPreparationPreview {
    let frame = authoritative_frame("fixture input");
    service
        .preview_authoritative(
            format!("preview-operation-{suffix}"),
            format!("preparation-{suffix}"),
            format!("proposed-run-{suffix}"),
            authoritative_start(frame.frame_ref().clone(), "fixture input"),
            &frame,
            now_millis,
        )
        .unwrap()
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
        BINDING_HASH,
        "",
    )
    .with_binding_identity("binding-1", 1)
    .with_computed_digest()
    .unwrap()
}

fn egress_attestation(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    registration: PreparedSessionRegistration,
) -> HostAttestation {
    HostAttestation::from_registration(registration, preview.binding_digest(), "", 2 * MINUTE)
        .with_document_context(
            preview.binding().requirements_hash(),
            RESOLVED_PARAMETERS_DIGEST,
        )
        .with_capability_snapshot_digest(CAPABILITY_PLACEHOLDER_DIGEST)
        .with_egress_scope(
            preview.binding().initial_disclosure_digest(),
            "disclosure-grant-1",
            ["text"],
            "private",
            OPAQUE_SUBJECT_DIGEST,
        )
        .with_computed_egress_digest()
        .unwrap()
}

fn egress_with_scope(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    registration: PreparedSessionRegistration,
    grant: &str,
    data_classes: &[&str],
    sensitivity: &str,
    subject: &str,
) -> HostAttestation {
    HostAttestation::from_registration(registration, preview.binding_digest(), "", 2 * MINUTE)
        .with_document_context(
            preview.binding().requirements_hash(),
            RESOLVED_PARAMETERS_DIGEST,
        )
        .with_capability_snapshot_digest(CAPABILITY_PLACEHOLDER_DIGEST)
        .with_egress_scope(
            preview.binding().initial_disclosure_digest(),
            grant,
            data_classes.iter().copied(),
            sensitivity,
            subject,
        )
        .with_computed_egress_digest()
        .unwrap()
}

fn valid_attestation(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    registration: PreparedSessionRegistration,
) -> HostAttestation {
    let capability = PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        2 * MINUTE,
    )
    .with_computed_digest()
    .unwrap();
    egress_attestation(preview, registration)
        .with_capability_attestation(capability)
        .with_computed_egress_digest()
        .unwrap()
}

fn capability_with_bad_digest(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedCapabilityAttestation {
    PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        2 * MINUTE,
    )
    .with_attestation_digest("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
}

fn capability_with_insufficient_context(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedCapabilityAttestation {
    PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        2 * MINUTE,
    )
    .with_context_length("0")
    .with_computed_digest()
    .unwrap()
}

fn capability_without_required_modality(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedCapabilityAttestation {
    PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        2 * MINUTE,
    )
    .with_input_modalities(std::iter::empty::<LLMInputModality>())
    .with_computed_digest()
    .unwrap()
}

fn capability_without_required_streaming(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedCapabilityAttestation {
    PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        2 * MINUTE,
    )
    .with_streaming(false)
    .with_computed_digest()
    .unwrap()
}

fn capability_without_required_tools(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedCapabilityAttestation {
    PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        2 * MINUTE,
    )
    .with_tool_calling(false)
    .with_computed_digest()
    .unwrap()
}

fn expired_capability(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
) -> PreparedCapabilityAttestation {
    PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        80_000,
    )
    .with_computed_digest()
    .unwrap()
}

fn install_exact_host_binding(
    state: &SharedAgentOSStateStore,
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    registration: &PreparedSessionRegistration,
) {
    state
        .with_host_binding_mut(|store| {
            let requirements = preview.binding().requirements().unwrap();
            let operation = store.prepare_profile_publish(ProfilePublishPreparation::new(
                format!("publish:{}", preview.preparation_id()),
                preview.binding().agent_profile_id(),
                preview.binding().agent_profile_revision(),
                requirements.slot_id(),
                preview.binding().requirements_hash(),
            ))?;
            let binding = HostBindingTuple::new(
                registration.binding_id(),
                registration.binding_revision(),
                registration.binding_hash(),
            );
            let receipt = HostBindingStagingReceipt::new(
                operation.token_digest(),
                operation.llm_slot_id(),
                operation.requirements_hash(),
                binding.clone(),
                format!("receipt:{}", preview.preparation_id()),
            );
            let link = store.commit_profile_publish(HostBindingCommit::new(
                operation.token(),
                binding,
                receipt,
            ))?;
            store.activate_matching_cross_link(&HostBindingActivationConfirmation::new(
                link.agent_profile_id(),
                link.agent_profile_revision(),
                link.llm_slot_id(),
                link.requirements_hash(),
                link.binding().clone(),
                link.staging_receipt_digest(),
            ))?;
            Ok(())
        })
        .unwrap();
}

#[test]
fn preview_freezes_binding_and_renewal_rotates_with_total_ceiling() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
    assert_eq!(preview.expiration_millis(), 5 * MINUTE);
    assert_eq!(preview.total_deadline_millis(), 30 * MINUTE);
    assert_eq!(preview.binding().agent_profile_id(), "profile_1");

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
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
    let registered = service
        .register_prepared_session(preview.token(), registration(&preview), MINUTE)
        .unwrap();
    install_exact_host_binding(&state, &preview, registered.registration().unwrap());
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
        BINDING_HASH,
        "registration-digest-1",
    );
    assert_eq!(
        service
            .register_prepared_session(preview.token(), conflict, MINUTE)
            .unwrap_err()
            .code(),
        "preparation.registration_conflict"
    );

    let attestation = valid_attestation(&preview, registration(&preview));
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
fn commit_validation_rejects_missing_capability_attestation() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state, "epoch-1");
    let preview = preview_fixture(&service, "missing-capability", 0);
    let registration = registration(&preview);
    service
        .register_prepared_session(preview.token(), registration.clone(), MINUTE)
        .unwrap();

    assert_eq!(
        service
            .commit_start(
                preview.token(),
                egress_attestation(&preview, registration),
                90_000,
            )
            .unwrap_err()
            .code(),
        "preparation.capability_attestation_missing"
    );
}

#[test]
fn commit_validation_rejects_capability_digest_and_claim_mutations() {
    type Mutation = fn(
        &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    ) -> PreparedCapabilityAttestation;
    for (suffix, capability, expected) in [
        (
            "capability-digest",
            capability_with_bad_digest as Mutation,
            "preparation.capability_attestation_digest_mismatch",
        ),
        (
            "capability-context",
            capability_with_insufficient_context as Mutation,
            "preparation.capability_attestation_mismatch",
        ),
        (
            "capability-modality",
            capability_without_required_modality as Mutation,
            "preparation.capability_attestation_mismatch",
        ),
        (
            "capability-streaming",
            capability_without_required_streaming as Mutation,
            "preparation.capability_attestation_mismatch",
        ),
        (
            "capability-tools",
            capability_without_required_tools as Mutation,
            "preparation.capability_attestation_mismatch",
        ),
        (
            "capability-expired",
            expired_capability as Mutation,
            "preparation.capability_attestation_mismatch",
        ),
    ] {
        let state = SharedAgentOSStateStore::in_memory();
        let service = test_service(state, "epoch-1");
        let preview = preview_fixture(&service, suffix, 0);
        let registration = registration(&preview);
        service
            .register_prepared_session(preview.token(), registration.clone(), MINUTE)
            .unwrap();
        let attestation = egress_attestation(&preview, registration)
            .with_capability_attestation(capability(&preview))
            .with_computed_egress_digest()
            .unwrap();
        assert_eq!(
            service
                .commit_start(preview.token(), attestation, 90_000)
                .unwrap_err()
                .code(),
            expected
        );
    }
}

#[test]
fn commit_validation_rehashes_frozen_source_and_model_input_bytes() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "rehash-frozen", 0);
    let registration = registration(&preview);
    service
        .register_prepared_session(preview.token(), registration.clone(), MINUTE)
        .unwrap();
    install_exact_host_binding(&state, &preview, &registration);
    let record = service
        .preparation(preview.preparation_id())
        .unwrap()
        .unwrap();
    let attestation = valid_attestation(&preview, registration.clone());

    let mut tampered_json = serde_json::to_value(&record).unwrap();
    tampered_json["preview"]["binding"]["source_revisions_digest"] =
        serde_json::Value::String("tampered-source-revisions".to_string());
    let tampered = serde_json::from_value(tampered_json).unwrap();
    assert_eq!(
        PreparedStartValidator::validate(&tampered, &attestation, None, None, 90_000)
            .unwrap_err()
            .code(),
        "preparation.binding_digest_mismatch"
    );

    let requirements = preview.binding().requirements().unwrap();
    let link = state
        .with_host_binding(|store| {
            store.matching_cross_link(
                preview.binding().agent_profile_id(),
                preview.binding().agent_profile_revision(),
                requirements.slot_id(),
                preview.binding().requirements_hash(),
                registration.binding_id(),
                registration.binding_revision(),
                registration.binding_hash(),
            )
        })
        .unwrap()
        .unwrap();
    assert_eq!(
        PreparedStartValidator::validate(&record, &attestation, Some(&link), Some(b"{}"), 90_000,)
            .unwrap_err()
            .code(),
        "preparation.frozen_model_input_digest_mismatch"
    );
}

#[test]
fn commit_validation_requires_exact_host_binding_cross_link() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state, "epoch-1");
    let preview = preview_fixture(&service, "missing-cross-link", 0);
    let registration = registration(&preview);
    service
        .register_prepared_session(preview.token(), registration.clone(), MINUTE)
        .unwrap();

    assert_eq!(
        service
            .commit_start(
                preview.token(),
                valid_attestation(&preview, registration),
                90_000,
            )
            .unwrap_err()
            .code(),
        "preparation.host_binding_cross_link_missing"
    );
}

#[test]
fn commit_rejects_unrecomputed_registration_and_egress_digests() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state, "epoch-1");
    let preview = preview_fixture(&service, "invalid-digest", 0);
    let registration = PreparedSessionRegistration::new(
        "invalid-register",
        preview.preparation_id(),
        preview.proposed_run_id(),
        "session-invalid",
        "snapshot-invalid",
        "epoch-1",
        "binding-hash-invalid",
        "caller-invented-registration-digest",
    );
    service
        .register_prepared_session(preview.token(), registration.clone(), MINUTE)
        .unwrap();
    let attestation = HostAttestation::from_registration(
        registration,
        preview.binding_digest(),
        "caller-invented-egress-digest",
        2 * MINUTE,
    );

    assert_eq!(
        service
            .commit_start(preview.token(), attestation, 90_000)
            .unwrap_err()
            .code(),
        "preparation.registration_digest_mismatch"
    );
}

#[test]
fn commit_rejects_unrecomputed_egress_digest() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state, "epoch-1");
    let preview = preview_fixture(&service, "invalid-egress", 0);
    let registration = registration(&preview);
    service
        .register_prepared_session(preview.token(), registration.clone(), MINUTE)
        .unwrap();
    let attestation = HostAttestation::from_registration(
        registration,
        preview.binding_digest(),
        "caller-invented-egress-digest",
        2 * MINUTE,
    )
    .with_document_context(
        preview.binding().requirements_hash(),
        RESOLVED_PARAMETERS_DIGEST,
    )
    .with_capability_snapshot_digest(CAPABILITY_PLACEHOLDER_DIGEST)
    .with_egress_scope(
        preview.binding().initial_disclosure_digest(),
        "disclosure-grant-1",
        ["text"],
        "private",
        OPAQUE_SUBJECT_DIGEST,
    );

    assert_eq!(
        service
            .commit_start(preview.token(), attestation, 90_000)
            .unwrap_err()
            .code(),
        "preparation.egress_attestation_digest_mismatch"
    );
}

#[test]
fn commit_validation_rejects_egress_public_field_mutations() {
    for (suffix, grant, classes, sensitivity, subject) in [
        (
            "egress-grant",
            "",
            &["text"][..],
            "private",
            OPAQUE_SUBJECT_DIGEST,
        ),
        (
            "egress-classes",
            "grant",
            &["attachment"][..],
            "private",
            OPAQUE_SUBJECT_DIGEST,
        ),
        (
            "egress-sensitivity",
            "grant",
            &["text"][..],
            "secret",
            OPAQUE_SUBJECT_DIGEST,
        ),
        (
            "egress-subject",
            "grant",
            &["text"][..],
            "private",
            ALTERNATE_OPAQUE_SUBJECT_DIGEST,
        ),
    ] {
        let state = SharedAgentOSStateStore::in_memory();
        let service = test_service(state, "epoch-1");
        let preview = preview_fixture(&service, suffix, 0);
        let registration = registration(&preview);
        service
            .register_prepared_session(preview.token(), registration.clone(), MINUTE)
            .unwrap();
        let capability = PreparedCapabilityAttestation::from_requirements(
            preview.binding().requirements().unwrap(),
            2 * MINUTE,
        )
        .with_computed_digest()
        .unwrap();
        let attestation =
            egress_with_scope(&preview, registration, grant, classes, sensitivity, subject)
                .with_capability_attestation(capability);
        assert_eq!(
            service
                .commit_start(preview.token(), attestation, 90_000)
                .unwrap_err()
                .code(),
            "preparation.egress_attestation_digest_mismatch"
        );
    }
}

#[test]
fn exact_prepared_close_receipt_is_required_to_release() {
    let state = SharedAgentOSStateStore::in_memory();
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
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
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
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
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
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

    let second = preview_fixture(&service, "2", MINUTE);
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
        "",
    )
    .with_binding_identity("binding-2", 1)
    .with_computed_digest()
    .unwrap()
}

#[test]
fn sqlite_preparation_record_survives_reopen_without_bearer() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let state = SharedAgentOSStateStore::new(SqliteAgentOSStateStore::open(&path).unwrap());
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
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
    let service = test_service(state.clone(), "epoch-1");
    let preview = preview_fixture(&service, "1", 0);
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
