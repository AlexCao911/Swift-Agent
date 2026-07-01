#[test]
fn runtime_layer_does_not_depend_on_builder_package_or_profile_repositories() {
    let runtime_source = include_str!("../../src/core/runtime.rs");

    for forbidden in [
        "agent_package",
        "AgentPackage",
        "AgentProfilePublisher",
        "InMemoryAgentProfileRepository",
        "ComponentCatalogService",
        "PackageInstall",
    ] {
        assert!(
            !runtime_source.contains(forbidden),
            "runtime layer must not depend on {forbidden}"
        );
    }
}

#[test]
fn agent_profile_reference_public_api_makes_latest_resolution_explicit() {
    let source = include_str!("../../src/user_customization/agent_profile.rs");

    assert!(
        !source.contains("pub fn new(profile_id: AgentProfileId) -> Self"),
        "versionless AgentProfileReference::new must not be public; use pinned(...) or latest(...)"
    );
    assert!(source.contains("pub fn pinned("));
    assert!(source.contains("pub fn latest("));
}
