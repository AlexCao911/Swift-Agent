use local_ios_agent_runtime::app_service::{
    AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::llm_contracts::{
    AgentHostBindingService, HostBindingActivationConfirmation, HostBindingCommit,
    HostBindingOperationState, HostBindingStagingReceipt, HostBindingSubjectCatalog,
    HostBindingTuple, ProfilePublishPreparation,
};
use local_ios_agent_runtime::storage::agent_os_state::SharedAgentOSStateStore;
use local_ios_agent_runtime::user_customization::{
    AgentProfileHostBindingState, AgentProfileId, AgentProfileReference, AgentProfileVersion,
};

#[test]
fn staging_receipt_is_bound_to_the_full_opaque_tuple() {
    let binding = HostBindingTuple::new("binding-1", 7, "binding-hash-1");
    let receipt = HostBindingStagingReceipt::new(
        "token-digest-1",
        "assistant",
        "requirements-hash-1",
        binding.clone(),
        "receipt-digest-1",
    );

    let commit = HostBindingCommit::new("publish-token-1", binding.clone(), receipt.clone());
    assert_eq!(commit.binding(), &binding);
    assert_eq!(commit.receipt(), &receipt);

    let mismatched = HostBindingTuple::new("binding-1", 8, "binding-hash-1");
    assert_ne!(receipt.binding(), &mismatched);
}

#[test]
fn host_binding_contract_contains_no_swift_owned_target_details() {
    let binding = HostBindingTuple::new("binding-1", 1, "opaque-hash");
    let receipt =
        HostBindingStagingReceipt::new("token-digest", "slot", "requirements", binding, "receipt");
    let json = serde_json::to_value(receipt).unwrap();
    let object = json.as_object().unwrap();

    for forbidden in [
        "provider",
        "provider_profile",
        "api_key",
        "credential",
        "base_url",
        "model_id",
        "local_path",
        "installation_id",
        "llm_target",
    ] {
        assert!(
            !object.contains_key(forbidden),
            "forbidden field: {forbidden}"
        );
    }
}

#[test]
fn semantic_profile_saga_binds_actual_revision_before_activation() {
    let app = AgentOSApplicationService::from_config(
        AgentOSApplicationServiceConfig::new().with_seed_development_profile(true),
    )
    .unwrap();
    let profiles = app.runtime_state();
    let profile_ref = AgentProfileReference::pinned(
        AgentProfileId::new("profile_v2"),
        AgentProfileVersion::new(1),
    );
    let profile = profiles
        .agent_profile_exact(profile_ref.profile_id(), AgentProfileVersion::new(1))
        .unwrap()
        .unwrap();
    assert_eq!(
        profile.host_binding_state(),
        AgentProfileHostBindingState::PendingHostBinding
    );
    assert!(app
        .list_agent_profiles()
        .iter()
        .all(|profile| profile.id().as_str() != "profile_v2"));
    let requirements = profile.llm_slot().unwrap().requirements();
    let requirements_hash = CanonicalDigestV1::digest("agent-requirements:v1", requirements)
        .unwrap()
        .as_str()
        .to_string();
    let state = SharedAgentOSStateStore::in_memory();
    let service =
        AgentHostBindingService::new(state, HostBindingSubjectCatalog::new(profiles.clone()));

    assert_eq!(
        service
            .prepare_profile_publish(ProfilePublishPreparation::new(
                "missing-profile",
                "does-not-exist",
                1,
                requirements.slot_id(),
                &requirements_hash,
            ))
            .unwrap_err()
            .code(),
        "host_binding.profile_revision_not_found"
    );
    let pending = service
        .prepare_profile_publish(ProfilePublishPreparation::new(
            "publish-profile-v2",
            "profile_v2",
            1,
            requirements.slot_id(),
            &requirements_hash,
        ))
        .unwrap();
    let binding = HostBindingTuple::new("binding-v2", 3, "binding-hash-v2");
    let receipt = HostBindingStagingReceipt::new(
        pending.token_digest(),
        pending.llm_slot_id(),
        pending.requirements_hash(),
        binding.clone(),
        "staging-receipt-v2",
    );
    let link = service
        .commit_profile_publish(HostBindingCommit::new(
            pending.token(),
            binding.clone(),
            receipt,
        ))
        .unwrap();
    assert_eq!(link.state(), HostBindingOperationState::HostUnbound);
    assert_eq!(
        profiles
            .agent_profile_exact(profile_ref.profile_id(), AgentProfileVersion::new(1))
            .unwrap()
            .unwrap()
            .host_binding_state(),
        AgentProfileHostBindingState::HostUnbound
    );
    assert!(app
        .list_agent_profiles()
        .iter()
        .all(|profile| profile.id().as_str() != "profile_v2"));

    let active = service
        .confirm_activation(HostBindingActivationConfirmation::new(
            "profile_v2",
            1,
            requirements.slot_id(),
            &requirements_hash,
            binding.clone(),
            link.staging_receipt_digest(),
        ))
        .unwrap();
    assert_eq!(active.state(), HostBindingOperationState::Active);
    let profile = profiles
        .agent_profile_exact(profile_ref.profile_id(), AgentProfileVersion::new(1))
        .unwrap()
        .unwrap();
    assert_eq!(
        profile.host_binding_state(),
        AgentProfileHostBindingState::Active
    );
    assert!(profile.readiness().is_ready());
    assert!(app
        .list_agent_profiles()
        .iter()
        .any(|profile| profile.id().as_str() == "profile_v2"));

    let rebind = service
        .prepare_profile_rebind(ProfilePublishPreparation::new(
            "rebind-profile-v2",
            "profile_v2",
            1,
            requirements.slot_id(),
            &requirements_hash,
        ))
        .unwrap();
    let replacement =
        HostBindingTuple::new("binding-v2-replacement", 1, "binding-hash-v2-replacement");
    let replacement_receipt = HostBindingStagingReceipt::new(
        rebind.token_digest(),
        rebind.llm_slot_id(),
        rebind.requirements_hash(),
        replacement.clone(),
        "staging-receipt-v2-replacement",
    );
    let replacement_link = service
        .commit_profile_rebind(HostBindingCommit::new(
            rebind.token(),
            replacement.clone(),
            replacement_receipt,
        ))
        .unwrap();
    assert_eq!(
        replacement_link.state(),
        HostBindingOperationState::HostUnbound
    );
    assert_eq!(
        profiles
            .agent_profile_exact(profile_ref.profile_id(), AgentProfileVersion::new(1))
            .unwrap()
            .unwrap()
            .host_binding_state(),
        AgentProfileHostBindingState::Active
    );
    let replacement_active = service
        .confirm_activation(HostBindingActivationConfirmation::new(
            "profile_v2",
            1,
            requirements.slot_id(),
            &requirements_hash,
            replacement,
            replacement_link.staging_receipt_digest(),
        ))
        .unwrap();
    assert_eq!(
        replacement_active.state(),
        HostBindingOperationState::Active
    );
    assert_eq!(
        service
            .confirm_activation(HostBindingActivationConfirmation::new(
                "profile_v2",
                1,
                requirements.slot_id(),
                &requirements_hash,
                binding,
                link.staging_receipt_digest(),
            ))
            .unwrap_err()
            .code(),
        "host_binding.activation_state_stale"
    );
}
