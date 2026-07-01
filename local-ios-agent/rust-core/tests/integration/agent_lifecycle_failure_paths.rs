use crate::support::agent_os_fixtures::AgentOsTestWorld;

use local_ios_agent_runtime::agent_package::{AgentPackageManifest, LocalBindings};
use local_ios_agent_runtime::security::{DataEgressRequest, SecurityManager};
use local_ios_agent_runtime::user_customization::{AgentProfileId, AgentProfileReference};

#[test]
fn lifecycle_fails_before_runtime_when_model_credential_binding_is_missing() {
    let world = AgentOsTestWorld::new();

    let error = world
        .package_installer()
        .install(
            AgentPackageManifest::fixture_valid(),
            LocalBindings::empty(),
        )
        .unwrap_err();

    assert_eq!(error.code(), "package.local_binding.model_account_required");
    assert!(world.package_store.installations().is_empty());
    assert!(world
        .profile_repository
        .profile(&AgentProfileReference::latest(AgentProfileId::new(
            "profile:agent.fixture"
        )))
        .is_none());
}

#[test]
fn lifecycle_fails_before_runtime_when_remote_model_egress_is_denied() {
    let security = SecurityManager::new();

    let decision = security.evaluate_egress(DataEgressRequest::remote_inference(
        "https://api.openai.com",
    ));

    assert!(
        !decision.allowlist_result().is_allowed(),
        "remote model egress must fail before Runtime when destination is not globally allowed"
    );
}
