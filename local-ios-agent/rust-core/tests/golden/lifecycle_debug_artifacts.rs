use crate::support::agent_os_fixtures::AgentOsTestWorld;
use crate::support::assertions::assert_redacted_debug_output;

use local_ios_agent_runtime::agent_package::AgentPackageManifest;
use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::run_snapshot::{RunSnapshotId, RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::security::{
    CredentialPurpose, InMemoryCredentialResolver, PermissionState, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::AgentProfileVersion;
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
    let error = service
        .resolve_and_persist(StartRunRequest::new(
            installed.profile().profile_id().as_str(),
            AgentProfileVersion::initial(),
            "golden run",
            frame_ref_fixture(),
        ))
        .unwrap_err();
    let actual = serde_json::to_string_pretty(&json!({
        "profile_id": installed.profile().profile_id().as_str(),
        "profile_version": AgentProfileVersion::initial().as_u64(),
        "execution": {
            "code": error.code(),
            "message": error.message(),
        },
        "snapshot_persisted": service.repository().contains(RunSnapshotId::new(1)),
    }))
    .unwrap()
        + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/run_snapshot_summary.json")
    );
}
