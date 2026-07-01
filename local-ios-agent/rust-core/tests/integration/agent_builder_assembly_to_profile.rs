use local_ios_agent_runtime::user_customization::{
    AgentBuilderInput, AgentBuilderResolver, AgentTemplate, UserEnvironment, UserProvidedBindings,
};

#[test]
fn builder_create_plan_finalize_produces_snapshot_consumable_profile() {
    let resolver = AgentBuilderResolver::fixture_with_openai_binding_request();
    let input = AgentBuilderInput::from_template(AgentTemplate::research_assistant());
    let plan = resolver
        .create_plan(input, &UserEnvironment::fixture_ready())
        .unwrap();

    assert!(plan.readiness_report().is_ready());
    assert!(plan
        .required_bindings()
        .iter()
        .any(|binding| binding.binding_key() == "credential.openai.api_key"));

    let profile = resolver
        .finalize(
            plan,
            UserProvidedBindings::default()
                .credential("credential.openai.api_key", "credential_ref.openai.default"),
        )
        .unwrap();

    assert!(profile.reference().profile_version().is_some());
    assert!(profile.readiness().is_ready());
    assert!(profile
        .bindings()
        .iter()
        .all(|binding| binding.component_version_id().is_published()));
}
