use local_ios_agent_runtime::conversation::{
    ConversationFrameId, ConversationFrameMessage, ConversationLineage, ConversationRunFrame,
    ConversationRunFrameRef,
};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::llm_contracts::{
    HostBindingActivationConfirmation, HostBindingCommit, HostBindingOperationState,
    HostBindingStagingReceipt, HostBindingTuple, PackageBindingPreparation,
    ProfilePublishPreparation,
};
use local_ios_agent_runtime::run_snapshot::{
    RunPreparationService, RunSnapshotService, StartRunRequest,
};
use local_ios_agent_runtime::storage::agent_os_state::{
    AgentOSStateRepository, SharedAgentOSStateStore, SqliteAgentOSStateStore,
};
use local_ios_agent_runtime::user_customization::AgentProfileVersion;

fn profile_request(key: &str) -> ProfilePublishPreparation {
    ProfilePublishPreparation::new(key, "profile-1", 4, "assistant", "requirements-hash-1")
}

#[test]
fn profile_publish_is_exactly_idempotent_and_survives_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let mut store = SqliteAgentOSStateStore::open(&path).unwrap();

    let pending = store
        .prepare_profile_publish(profile_request("publish-op-1"))
        .unwrap();
    assert_ne!(pending.token(), pending.token_digest());
    assert_eq!(
        store
            .prepare_profile_publish(profile_request("publish-op-1"))
            .unwrap(),
        pending
    );
    let conflict = ProfilePublishPreparation::new(
        "publish-op-1",
        "profile-1",
        4,
        "different-slot",
        "requirements-hash-1",
    );
    assert_eq!(
        store.prepare_profile_publish(conflict).unwrap_err().code(),
        "host_binding.idempotency_conflict"
    );

    let binding = HostBindingTuple::new("binding-1", 3, "binding-hash-1");
    let receipt = HostBindingStagingReceipt::new(
        pending.token_digest(),
        pending.llm_slot_id(),
        pending.requirements_hash(),
        binding.clone(),
        "receipt-digest-1",
    );
    let commit = HostBindingCommit::new(pending.token(), binding.clone(), receipt);
    let cross_link = store.commit_profile_publish(commit.clone()).unwrap();
    assert_eq!(cross_link.state(), HostBindingOperationState::HostUnbound);
    assert_eq!(cross_link.binding(), &binding);
    assert_eq!(store.commit_profile_publish(commit).unwrap(), cross_link);
    drop(store);

    let store = SqliteAgentOSStateStore::open(&path).unwrap();
    assert_eq!(store.cross_link(pending.token()).unwrap(), Some(cross_link));
}

#[test]
fn exact_activation_is_durable_and_idempotent() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let mut store = SqliteAgentOSStateStore::open(&path).unwrap();
    let pending = store
        .prepare_profile_publish(profile_request("activate-profile"))
        .unwrap();
    let binding = HostBindingTuple::new("binding-active", 2, "binding-active-hash");
    let link = store
        .commit_profile_publish(HostBindingCommit::new(
            pending.token(),
            binding.clone(),
            HostBindingStagingReceipt::new(
                pending.token_digest(),
                pending.llm_slot_id(),
                pending.requirements_hash(),
                binding.clone(),
                "activation-receipt",
            ),
        ))
        .unwrap();
    let confirmation = HostBindingActivationConfirmation::new(
        link.agent_profile_id(),
        link.agent_profile_revision(),
        link.llm_slot_id(),
        link.requirements_hash(),
        binding,
        link.staging_receipt_digest(),
    );
    let active = store.activate_matching_cross_link(&confirmation).unwrap();
    assert_eq!(active.state(), HostBindingOperationState::Active);
    assert_eq!(
        store.activate_matching_cross_link(&confirmation).unwrap(),
        active
    );
    drop(store);

    let store = SqliteAgentOSStateStore::open(&path).unwrap();
    assert_eq!(
        store.cross_link(pending.token()).unwrap().unwrap().state(),
        HostBindingOperationState::Active
    );
}

#[test]
fn commit_rejects_any_binding_or_receipt_mismatch() {
    let mut store = SqliteAgentOSStateStore::open_in_memory().unwrap();
    let pending = store
        .prepare_profile_publish(profile_request("publish-op-2"))
        .unwrap();
    let staged = HostBindingTuple::new("binding-1", 3, "binding-hash-1");
    let sent = HostBindingTuple::new("binding-1", 4, "binding-hash-1");
    let receipt = HostBindingStagingReceipt::new(
        pending.token_digest(),
        pending.llm_slot_id(),
        pending.requirements_hash(),
        staged,
        "receipt-digest-2",
    );

    let error = store
        .commit_profile_publish(HostBindingCommit::new(pending.token(), sent, receipt))
        .unwrap_err();
    assert_eq!(error.code(), "host_binding.binding_mismatch");
    assert!(store.cross_link(pending.token()).unwrap().is_none());
}

#[test]
fn package_binding_uses_the_same_durable_saga_rules() {
    let mut store = SqliteAgentOSStateStore::open_in_memory().unwrap();
    let pending = store
        .begin_package_binding(PackageBindingPreparation::new(
            "package-op-1",
            "installation-1",
            "profile-2",
            1,
            "assistant",
            "requirements-hash-2",
        ))
        .unwrap();
    let binding = HostBindingTuple::new("binding-2", 1, "binding-hash-2");
    let receipt = HostBindingStagingReceipt::new(
        pending.token_digest(),
        pending.llm_slot_id(),
        pending.requirements_hash(),
        binding.clone(),
        "receipt-digest-3",
    );
    let attached = store
        .attach_host_binding(HostBindingCommit::new(
            pending.token(),
            binding.clone(),
            receipt,
        ))
        .unwrap();

    assert_eq!(attached.binding(), &binding);
    assert_eq!(attached.state(), HostBindingOperationState::HostUnbound);
}

#[test]
fn schema_contains_all_phase_one_agent_os_tables() {
    let store = SqliteAgentOSStateStore::open_in_memory().unwrap();
    let names = store.table_names().unwrap();
    for required in [
        "global_run_lease",
        "host_binding_operations",
        "host_binding_cross_links",
        "preparation_cleanup_outbox",
        "preparation_cleanup_receipts",
        "run_preparations",
    ] {
        assert!(
            names.iter().any(|name| name == required),
            "missing {required}"
        );
    }
}

#[test]
fn host_binding_bearer_is_random_and_never_persisted() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let raw = {
        let mut store = SqliteAgentOSStateStore::open(&path).unwrap();
        let pending = store
            .prepare_profile_publish(profile_request("random-publish-op"))
            .unwrap();
        assert_eq!(pending.token().len(), 43);
        assert!(pending
            .token()
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'));
        pending.token().to_string()
    };

    let connection = rusqlite::Connection::open(&path).unwrap();
    let occurrences: i64 = connection
        .query_row(
            "select count(*) from host_binding_operations where operation_token = ?1 or token_digest = ?1",
            [&raw],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(occurrences, 0);
}

#[test]
fn preparation_bearer_is_not_serialized_into_sqlite_record() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent-os.sqlite");
    let raw = {
        let store = SqliteAgentOSStateStore::open(&path).unwrap();
        let state = SharedAgentOSStateStore::new(store);
        let service = RunPreparationService::with_authoritative_preview(
            state,
            "epoch-random",
            std::sync::Arc::new(RunSnapshotService::fixture_with_host_slot_v2()),
        );
        let frame_ref = ConversationRunFrameRef::new(
            ConversationFrameId::new("random-frame"),
            SessionId("random-session".to_string()),
            EntryId("random-branch".to_string()),
            EntryId("random-turn".to_string()),
        );
        let frame = ConversationRunFrame::new(
            frame_ref.clone(),
            None,
            vec![ConversationFrameMessage::user(
                EntryId("random-turn".to_string()),
                "random input",
            )],
            vec![],
            ConversationLineage::new(EntryId("random-branch".to_string()), None, None),
        );
        let preview = service
            .preview_authoritative(
                "random-preview-op",
                "random-preparation",
                "random-proposed-run",
                StartRunRequest::new(
                    "profile_1",
                    AgentProfileVersion::new(1),
                    "random input",
                    frame_ref,
                ),
                &frame,
                0,
            )
            .unwrap();
        assert_eq!(preview.token().len(), 43);
        preview.token().to_string()
    };

    let connection = rusqlite::Connection::open(&path).unwrap();
    let occurrences: i64 = connection
        .query_row(
            "select count(*) from run_preparations where record_json like '%' || ?1 || '%' or token_digest = ?1",
            [&raw],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(occurrences, 0);
}
