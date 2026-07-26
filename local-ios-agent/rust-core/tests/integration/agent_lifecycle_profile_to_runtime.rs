use crate::support::agent_os_fixtures::AgentOsTestWorld;

use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::llm_contracts::LLMBindingSchema;
use local_ios_agent_runtime::run_snapshot::{RunSnapshotId, RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::security::{
    CredentialPurpose, InMemoryCredentialResolver, PermissionState, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;

fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

#[test]
fn package_install_profile_requires_host_binding_without_concrete_model_state() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();

    assert_eq!(profile.id().as_str(), "profile:agent.fixture");
    assert!(profile.model_binding().is_none());
    assert!(profile.llm_slot().is_some());
    assert!(profile.local_bindings().is_empty());
    assert!(profile.readiness().has_issue("host_binding.missing"));
}

#[test]
fn host_slot_v2_stops_before_legacy_snapshot_model_resolution() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let service = RunSnapshotService::from_real_repositories(
        world.profile_repository.clone(),
        world.component_catalog.clone(),
        world.model_catalog.clone(),
        std::sync::Arc::new(
            StaticSecurityPermissionService::default()
                .with_permission("run.start", PermissionState::Granted),
        ),
        std::sync::Arc::new(InMemoryCredentialResolver::default().with_secret_for(
            "credential.openai.default",
            "secret",
            [CredentialPurpose::RemoteProvider],
        )),
        Box::new(InMemoryTransactionRunner::default()),
    );

    let error = service
        .resolve_and_persist(StartRunRequest::new(
            installed.profile().profile_id().as_str(),
            installed.profile().profile_version().unwrap(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "execution.host_slot_v2_requires_preparation");
    assert!(!service.repository().contains(RunSnapshotId::new(1)));
}

#[test]
fn host_slot_v2_gate_precedes_permission_and_repository_commit() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let service = RunSnapshotService::from_real_repositories(
        world.profile_repository.clone(),
        world.component_catalog.clone(),
        world.model_catalog.clone(),
        std::sync::Arc::new(
            StaticSecurityPermissionService::default()
                .with_permission("run.start", PermissionState::Denied),
        ),
        std::sync::Arc::new(InMemoryCredentialResolver::default().with_secret_for(
            "credential.openai.default",
            "secret",
            [CredentialPurpose::RemoteProvider],
        )),
        Box::new(InMemoryTransactionRunner::default()),
    );

    let error = service
        .resolve_and_persist(StartRunRequest::new(
            installed.profile().profile_id().as_str(),
            installed.profile().profile_version().unwrap(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "execution.host_slot_v2_requires_preparation");
    assert!(!service.repository().contains(RunSnapshotId::new(1)));
}

#[test]
fn exact_profile_revision_has_one_authoritative_execution_route() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let service = RunSnapshotService::from_real_repositories(
        world.profile_repository,
        world.component_catalog,
        world.model_catalog,
        std::sync::Arc::new(StaticSecurityPermissionService::default()),
        std::sync::Arc::new(InMemoryCredentialResolver::default()),
        Box::new(InMemoryTransactionRunner::default()),
    );
    let reference = installed.profile();

    let route = service
        .profile_execution_route(reference.profile_id(), reference.profile_version().unwrap())
        .unwrap();

    assert_eq!(route.schema_version(), 1);
    assert_eq!(route.profile_id(), reference.profile_id().as_str());
    assert_eq!(
        route.profile_revision(),
        reference.profile_version().unwrap().as_u64()
    );
    assert_eq!(route.llm_binding_schema(), LLMBindingSchema::HostSlotV2);
}
