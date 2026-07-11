use crate::support::agent_os_fixtures::AgentOsTestWorld;

use local_ios_agent_runtime::agent_package::AgentPackageManifest;
use local_ios_agent_runtime::security::{DataEgressRequest, SecurityManager};

#[test]
fn package_install_does_not_require_model_credential_before_host_binding() {
    let world = AgentOsTestWorld::new();

    let installed = world
        .package_installer()
        .install(AgentPackageManifest::fixture_valid())
        .unwrap();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();

    assert!(profile.local_bindings().is_empty());
    assert!(profile.readiness().has_issue("host_binding.missing"));
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
