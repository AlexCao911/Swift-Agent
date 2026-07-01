use crate::support::agent_os_fixtures::AgentOsTestWorld;

#[test]
fn package_install_profile_binding_readiness_path_is_runtime_ready() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();
    let model_binding = profile.model_binding().unwrap();

    assert_eq!(profile.id().as_str(), "profile:agent.fixture");
    assert!(profile.readiness().is_ready());
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
