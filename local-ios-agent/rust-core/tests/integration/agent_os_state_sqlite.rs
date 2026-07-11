use local_ios_agent_runtime::llm_contracts::{
    HostBindingCommit, HostBindingOperationState, HostBindingStagingReceipt, HostBindingTuple,
    PackageBindingPreparation, ProfilePublishPreparation,
};
use local_ios_agent_runtime::storage::agent_os_state::{
    AgentOSStateRepository, SqliteAgentOSStateStore,
};

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
        "run_preparations",
    ] {
        assert!(
            names.iter().any(|name| name == required),
            "missing {required}"
        );
    }
}
