use std::sync::{Arc, Barrier};

use local_ios_agent_runtime::conversation::{
    ConversationFrameId, ConversationFrameMessage, ConversationLineage, ConversationRunFrame,
    ConversationRunFrameRef,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::llm_contracts::{
    HostAttestation, HostBindingActivationConfirmation, HostBindingCommit,
    HostBindingStagingReceipt, HostBindingTuple, HostCommandKind, PreparationReconciliation,
    PreparedCapabilityAttestation, PreparedSessionRegistration, ProfilePublishPreparation,
};
use local_ios_agent_runtime::run_snapshot::{
    PersistedResolvedRunSnapshotV2, ResolvedRunSnapshot, RunPreparationService, RunSnapshotService,
    StartRunRequest,
};
use local_ios_agent_runtime::storage::{
    InMemoryRuntimeStateStore, RuntimeAggregateFailurePoint, RuntimeAggregateInspection,
    SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use local_ios_agent_runtime::user_customization::AgentProfileVersion;

const EPOCH: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const BINDING_HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const RESOLVED_PARAMETERS_DIGEST: &str =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const CAPABILITY_DIGEST: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const OPAQUE_SUBJECT_DIGEST: &str =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";

#[test]
fn commit_start_persists_provider_neutral_v2_snapshot_and_first_command_atomically() {
    let harness = HostPreparationHarness::ready("commit");

    let handle = harness
        .service
        .commit_start(harness.preview.token(), harness.attestation(), 90_000)
        .unwrap();

    assert_eq!(handle.run_id(), harness.preview.proposed_run_id());
    assert_eq!(
        handle.session_handle(),
        harness.registration.session_handle()
    );
    let commands = harness.runtime.pending_host_commands().unwrap();
    assert_eq!(commands.len(), 1);
    let command = commands[0].payload().unwrap();
    assert_eq!(command.kind(), HostCommandKind::StartGeneration);
    assert_eq!(
        command.payload().model_input_id,
        harness.preview.binding().model_input_id()
    );
    assert_eq!(
        command.payload().source_revisions_digest,
        harness.preview.binding().source_revisions_digest()
    );
    assert_eq!(
        command.payload().tool_schema_digest,
        harness.preview.binding().tool_schema_digest()
    );
    assert!(command.payload().tool_results.is_empty());
    assert!(command
        .payload()
        .messages
        .iter()
        .flat_map(|message| &message.content)
        .any(|content| content.text.as_deref() == Some("hello")));
    assert_eq!(
        command.disclosure.as_ref().unwrap(),
        harness.preview.initial_disclosure()
    );
    assert_eq!(
        command.disclosure.as_ref().unwrap().content_digest,
        command.payload().agent_input_digest().unwrap()
    );
    assert_eq!(handle.first_command_id(), command.command_id());

    let snapshot_json = harness
        .runtime
        .run_snapshot_json(handle.run_id())
        .unwrap()
        .unwrap();
    let snapshot: serde_json::Value = serde_json::from_str(&snapshot_json).unwrap();
    assert_eq!(snapshot["schema_version"], 2);
    assert_eq!(
        snapshot["llm_binding"]["requirements_hash"],
        harness.preview.binding().requirements_hash()
    );
    assert_eq!(snapshot["llm_binding"]["binding_id"], "binding-1");
    assert_eq!(
        snapshot["host_attestation"]["document"]["resolved_parameters_digest"],
        RESOLVED_PARAMETERS_DIGEST
    );
    assert_eq!(
        snapshot["host_attestation"]["document"]["opaque_egress_subject_digest"],
        OPAQUE_SUBJECT_DIGEST
    );
    for forbidden in [
        "provider_account_id",
        "provider_id",
        "model_id",
        "credential",
        "origin",
        "base_url",
        "installation_path",
        "adapter",
    ] {
        assert!(!contains_key(&snapshot["llm_binding"], forbidden));
    }

    let persisted: PersistedResolvedRunSnapshotV2 = serde_json::from_str(&snapshot_json).unwrap();
    assert_eq!(serde_json::to_value(&persisted).unwrap(), snapshot);
    let resolved = ResolvedRunSnapshot::try_from(persisted).unwrap();
    let host_binding = resolved.host_slot_binding();
    assert_eq!(
        host_binding.requirements_hash(),
        harness.preview.binding().requirements_hash()
    );
    assert_eq!(host_binding.host_cross_link().binding_id(), "binding-1");

    let mut injected = snapshot;
    injected["llm_binding"]["provider_id"] =
        serde_json::Value::String("must-not-be-accepted".into());
    assert!(
        serde_json::from_value::<PersistedResolvedRunSnapshotV2>(injected).is_err(),
        "host_slot_v2 persisted binding must reject provider-owned fields"
    );
}

#[test]
fn lost_commit_response_reconciles_exact_handle_without_creating_cleanup() {
    let harness = HostPreparationHarness::ready("reconcile");
    let expected = harness
        .service
        .commit_start(harness.preview.token(), harness.attestation(), 90_000)
        .unwrap();

    let outcome = harness
        .service
        .reconcile_preparation(
            harness.preview.preparation_id(),
            harness.preview.proposed_run_id(),
            harness.preview.token_digest(),
        )
        .unwrap();

    assert_eq!(
        outcome,
        PreparationReconciliation::Committed { handle: expected }
    );
    assert_eq!(harness.runtime.pending_host_commands().unwrap().len(), 1);
    assert!(harness
        .service
        .preparation(harness.preview.preparation_id())
        .unwrap()
        .is_none());
    assert_eq!(
        harness
            .service
            .begin_abort_preparation(
                harness.preview.preparation_id(),
                Some(harness.preview.token()),
                "late-abort",
                local_ios_agent_runtime::llm_contracts::PreparationAbortReason::CommitRejected,
            )
            .unwrap_err()
            .code(),
        "preparation.already_committed"
    );
}

#[test]
fn reconciliation_is_read_only_for_pending_and_returns_exact_aborting_cleanup_identity() {
    let harness = HostPreparationHarness::ready("pending-aborting");
    assert_eq!(
        harness
            .service
            .reconcile_preparation(
                harness.preview.preparation_id(),
                harness.preview.proposed_run_id(),
                harness.preview.token_digest(),
            )
            .unwrap(),
        PreparationReconciliation::Pending
    );
    assert_eq!(harness.runtime.pending_host_commands().unwrap().len(), 0);
    for (preparation_id, run_id, token_digest) in [
        (
            "wrong-preparation",
            harness.preview.proposed_run_id(),
            harness.preview.token_digest(),
        ),
        (
            harness.preview.preparation_id(),
            "wrong-run",
            harness.preview.token_digest(),
        ),
        (
            harness.preview.preparation_id(),
            harness.preview.proposed_run_id(),
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        ),
    ] {
        assert_eq!(
            harness
                .service
                .reconcile_preparation(preparation_id, run_id, token_digest)
                .unwrap_err()
                .code(),
            "preparation.reconciliation_identity_mismatch"
        );
    }

    let aborting = harness
        .service
        .begin_abort_preparation(
            harness.preview.preparation_id(),
            Some(harness.preview.token()),
            "abort-before-commit",
            local_ios_agent_runtime::llm_contracts::PreparationAbortReason::UserDenied,
        )
        .unwrap();
    let expected = aborting.cleanup().unwrap();
    let outcome = harness
        .service
        .reconcile_preparation(
            harness.preview.preparation_id(),
            harness.preview.proposed_run_id(),
            harness.preview.token_digest(),
        )
        .unwrap();
    match outcome {
        PreparationReconciliation::Aborting { cleanup_identity } => {
            assert_eq!(
                cleanup_identity.cleanup_command_id(),
                expected.cleanup_command_id()
            );
            assert_eq!(
                cleanup_identity.registration_digest(),
                expected.prepared_session_registration_digest()
            );
        }
        other => panic!("expected aborting reconciliation, got {other:?}"),
    }
    assert_eq!(harness.runtime.pending_host_commands().unwrap().len(), 0);
}

#[test]
fn sqlite_phase_c_and_reconciliation_survive_reopen_as_one_complete_aggregate() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let runtime = SqliteRuntimeStateStore::open(&path).unwrap();
    let service = RunPreparationService::with_host_runtime(
        runtime.agent_os_state(),
        EPOCH,
        Arc::new(RunSnapshotService::fixture_with_host_slot_v2()),
        Arc::new(runtime.clone()),
    );
    let frame = frame();
    let preview = service
        .preview_authoritative(
            "preview-sqlite",
            "preparation-sqlite",
            "run-sqlite",
            StartRunRequest::new(
                "profile_1",
                AgentProfileVersion::new(1),
                "hello",
                frame.frame_ref().clone(),
            ),
            &frame,
            0,
        )
        .unwrap();
    let registration = PreparedSessionRegistration::new(
        "registration-sqlite",
        preview.preparation_id(),
        preview.proposed_run_id(),
        "session-sqlite",
        "swift-snapshot-sqlite",
        EPOCH,
        BINDING_HASH,
        "",
    )
    .with_binding_identity("binding-1", 5)
    .with_computed_digest()
    .unwrap();
    service
        .register_prepared_session(preview.token(), registration.clone(), 60_000)
        .unwrap();
    install_exact_binding(runtime.agent_os_state(), &preview, &registration);
    let expected = service
        .commit_start(
            preview.token(),
            attestation(&preview, &registration),
            90_000,
        )
        .unwrap();
    let token_digest = preview.token_digest().to_string();
    drop(service);
    drop(runtime);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    assert_eq!(
        reopened
            .reconcile_preparation("preparation-sqlite", "run-sqlite", &token_digest)
            .unwrap(),
        PreparationReconciliation::Committed { handle: expected }
    );
    assert_eq!(reopened.pending_host_commands().unwrap().len(), 1);
    assert!(reopened.run_snapshot_json("run-sqlite").unwrap().is_some());
}

#[test]
fn every_phase_c_crash_point_leaves_the_registered_preparation_retryable() {
    for failure_point in RuntimeAggregateFailurePoint::phase_c_points() {
        let harness = HostPreparationHarness::ready(&format!("crash-{failure_point:?}"));
        harness.runtime.inject_failure(failure_point);

        assert!(harness
            .service
            .commit_start(harness.preview.token(), harness.attestation(), 90_000)
            .is_err());
        assert_eq!(
            harness
                .runtime
                .inspect_v2_aggregate(
                    harness.preview.preparation_id(),
                    harness.preview.proposed_run_id(),
                    harness.registration.session_handle(),
                )
                .unwrap(),
            RuntimeAggregateInspection::EMPTY
        );
        assert_eq!(
            harness
                .service
                .reconcile_preparation(
                    harness.preview.preparation_id(),
                    harness.preview.proposed_run_id(),
                    harness.preview.token_digest(),
                )
                .unwrap(),
            PreparationReconciliation::Pending
        );
        assert!(harness
            .service
            .commit_start(harness.preview.token(), harness.attestation(), 90_000)
            .is_ok());
    }
}

#[test]
fn concurrent_commit_and_abort_have_one_authoritative_winner() {
    let harness = HostPreparationHarness::ready("commit-abort-race");
    let barrier = Arc::new(Barrier::new(2));
    let commit_service = harness.service.clone();
    let commit_preview = harness.preview.clone();
    let commit_attestation = harness.attestation();
    let commit_barrier = barrier.clone();
    let commit = std::thread::spawn(move || {
        commit_barrier.wait();
        commit_service.commit_start(commit_preview.token(), commit_attestation, 90_000)
    });
    let abort_service = harness.service.clone();
    let abort_preview = harness.preview.clone();
    let abort = std::thread::spawn(move || {
        barrier.wait();
        abort_service.begin_abort_preparation(
            abort_preview.preparation_id(),
            Some(abort_preview.token()),
            "race-abort",
            local_ios_agent_runtime::llm_contracts::PreparationAbortReason::UserDenied,
        )
    });
    let commit = commit.join().unwrap();
    let abort = abort.join().unwrap();

    assert_ne!(commit.is_ok(), abort.is_ok());
    let outcome = harness
        .service
        .reconcile_preparation(
            harness.preview.preparation_id(),
            harness.preview.proposed_run_id(),
            harness.preview.token_digest(),
        )
        .unwrap();
    if commit.is_ok() {
        assert!(matches!(
            outcome,
            PreparationReconciliation::Committed { .. }
        ));
        assert_eq!(abort.unwrap_err().code(), "preparation.already_committed");
    } else {
        assert!(matches!(
            outcome,
            PreparationReconciliation::Aborting { .. }
        ));
    }
}

struct HostPreparationHarness {
    runtime: InMemoryRuntimeStateStore,
    service: RunPreparationService,
    preview: local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    registration: PreparedSessionRegistration,
}

impl HostPreparationHarness {
    fn ready(suffix: &str) -> Self {
        let runtime = InMemoryRuntimeStateStore::new();
        let service = RunPreparationService::with_host_runtime(
            runtime.agent_os_state(),
            EPOCH,
            Arc::new(RunSnapshotService::fixture_with_host_slot_v2()),
            Arc::new(runtime.clone()),
        );
        let frame = frame();
        let preview = service
            .preview_authoritative(
                format!("preview-{suffix}"),
                format!("preparation-{suffix}"),
                format!("run-{suffix}"),
                StartRunRequest::new(
                    "profile_1",
                    AgentProfileVersion::new(1),
                    "hello",
                    frame.frame_ref().clone(),
                ),
                &frame,
                0,
            )
            .unwrap();
        let registration = PreparedSessionRegistration::new(
            format!("registration-{suffix}"),
            preview.preparation_id(),
            preview.proposed_run_id(),
            format!("session-{suffix}"),
            format!("swift-snapshot-{suffix}"),
            EPOCH,
            BINDING_HASH,
            "",
        )
        .with_binding_identity("binding-1", 5)
        .with_computed_digest()
        .unwrap();
        service
            .register_prepared_session(preview.token(), registration.clone(), 60_000)
            .unwrap();
        install_exact_binding(runtime.agent_os_state(), &preview, &registration);
        Self {
            runtime,
            service,
            preview,
            registration,
        }
    }

    fn attestation(&self) -> HostAttestation {
        attestation(&self.preview, &self.registration)
    }
}

fn install_exact_binding(
    state: local_ios_agent_runtime::storage::agent_os_state::SharedAgentOSStateStore,
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

fn attestation(
    preview: &local_ios_agent_runtime::llm_contracts::RunPreparationPreview,
    registration: &PreparedSessionRegistration,
) -> HostAttestation {
    let capability = PreparedCapabilityAttestation::from_requirements(
        preview.binding().requirements().unwrap(),
        120_000,
    )
    .with_computed_digest()
    .unwrap();
    HostAttestation::from_registration(registration.clone(), preview.binding_digest(), "", 120_000)
        .with_document_context(
            preview.binding().requirements_hash(),
            RESOLVED_PARAMETERS_DIGEST,
        )
        .with_capability_snapshot_digest(CAPABILITY_DIGEST)
        .with_egress_scope(
            preview.binding().initial_disclosure_digest(),
            "grant-1",
            ["text"],
            "private",
            OPAQUE_SUBJECT_DIGEST,
        )
        .with_capability_attestation(capability)
        .with_computed_egress_digest()
        .unwrap()
}

fn frame() -> ConversationRunFrame {
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame-1"),
        SessionId("conversation-1".into()),
        EntryId("branch-1".into()),
        EntryId("turn-1".into()),
    );
    ConversationRunFrame::new(
        frame_ref,
        None,
        vec![ConversationFrameMessage::user(
            EntryId("turn-1".into()),
            "hello",
        )],
        vec![],
        ConversationLineage::new(EntryId("branch-1".into()), None, None),
    )
}

fn contains_key(value: &serde_json::Value, key: &str) -> bool {
    match value {
        serde_json::Value::Object(object) => {
            object.contains_key(key) || object.values().any(|value| contains_key(value, key))
        }
        serde_json::Value::Array(values) => values.iter().any(|value| contains_key(value, key)),
        _ => false,
    }
}
