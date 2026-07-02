use crate::support::agent_os_fixtures::AgentOsTestWorld;
use crate::support::assertions::assert_redacted_debug_output;

use local_ios_agent_runtime::agent_package::AgentPackageManifest;
use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::run_snapshot::{RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::security::{
    CredentialPurpose, InMemoryCredentialResolver, PermissionState, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use serde_json::json;

fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

#[test]
fn package_install_preview_matches_golden_and_mentions_all_transaction_writes() {
    let world = AgentOsTestWorld::new();
    let preview = world
        .package_installer()
        .preview(&AgentPackageManifest::fixture_valid());
    let actual = serde_json::to_string_pretty(&preview).unwrap() + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/package_install_preview.json")
    );
}

#[test]
fn installed_profile_debug_summary_matches_golden_and_is_redacted() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();
    let actual = serde_json::to_string_pretty(&profile.debug_summary()).unwrap() + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/profile_summary.json")
    );
}

#[test]
fn package_installed_run_snapshot_summary_matches_golden_and_is_redacted() {
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
            "redacted-value",
            [CredentialPurpose::RemoteProvider],
        )),
        Box::new(InMemoryTransactionRunner::default()),
    );
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new(
            installed.profile().profile_id().as_str(),
            "golden run",
            frame_ref_fixture(),
        ))
        .unwrap();
    let model_account = snapshot.model_binding().provider_account_id();
    let actual = serde_json::to_string_pretty(&json!({
        "snapshot_id": snapshot.snapshot_id().as_u64(),
        "profile_id": snapshot.agent_profile_id().as_str(),
        "profile_version": snapshot.profile_version().as_u64(),
        "component_versions": snapshot.component_versions().iter().map(|component| json!({
            "slot_id": component.slot_id().as_str(),
            "slot_kind": format!("{:?}", component.slot_kind()).to_lowercase(),
            "version_id": component.version_id().as_str(),
            "entity_version": component.entity_version().as_u64(),
        })).collect::<Vec<_>>(),
        "model_binding": {
            "binding_id": snapshot.model_binding().binding_id(),
            "provider_account_id": model_account,
            "provider_id": snapshot.model_binding().provider_id(),
            "model_id": snapshot.model_binding().model_id().as_str(),
            "catalog_version": snapshot.model_binding().catalog_version().as_u64(),
        },
        "trusted_host_state": {
            "permission_state": format!("{:?}", snapshot.trusted_host_state().permission_state()).to_lowercase(),
            "model_credential_available": snapshot
                .trusted_host_state()
                .credential_availability()
                .credential_ref_for(model_account)
                .is_some(),
        },
        "readiness": {
            "ready": snapshot.readiness_report().is_ready(),
            "issues": snapshot.readiness_report().issues().iter().map(|issue| issue.code()).collect::<Vec<_>>(),
        }
    }))
    .unwrap()
        + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/run_snapshot_summary.json")
    );
}
