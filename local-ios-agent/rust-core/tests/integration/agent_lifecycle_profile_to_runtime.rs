use crate::support::agent_os_fixtures::AgentOsTestWorld;

use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
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
fn package_install_profile_model_binding_readiness_is_satisfied() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();
    let model_binding = profile.model_binding().unwrap();

    assert_eq!(profile.id().as_str(), "profile:agent.fixture");
    assert!(
        profile.readiness().is_ready(),
        "package-installed profile should satisfy model binding readiness; full runtime readiness belongs to snapshot/application services"
    );
    assert!(
        world
            .model_catalog
            .contains_exact_selection(model_binding.selection()),
        "runtime snapshot resolution needs package-installed model selection to be catalog-resolvable"
    );
    assert_eq!(
        profile
            .local_bindings()
            .credential_ref(model_binding.selection().provider_account_id()),
        Some("credential.openai.default")
    );
}

#[test]
fn package_install_profile_resolves_to_persisted_run_snapshot() {
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

    let snapshot = service
        .resolve_and_persist(StartRunRequest::new(
            installed.profile().profile_id().as_str(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap();

    assert!(service.repository().contains(snapshot.snapshot_id()));
    assert_eq!(
        snapshot.agent_profile_id(),
        installed.profile().profile_id()
    );
    assert_eq!(
        snapshot.profile_version(),
        installed.profile().profile_version().unwrap()
    );
    assert!(snapshot.component_versions().is_empty());
    assert_eq!(snapshot.model_binding().model_id().as_str(), "gpt-fixture");
    assert!(snapshot.readiness_report().is_ready());
    assert_eq!(
        snapshot
            .trusted_host_state()
            .credential_availability()
            .credential_ref_for("package.provider_account:agent.fixture:model.account"),
        Some("credential.openai.default")
    );
}

#[test]
fn run_snapshot_denied_permission_stops_before_repository_commit() {
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
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.not_ready");
    assert!(!service.repository().contains(RunSnapshotId::new(1)));
}
