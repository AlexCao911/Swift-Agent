use local_ios_agent_runtime::user_customization::{
    AgentBuilderInput, AgentBuilderResolver, AgentSlotKind, AgentTemplate, UserEnvironment,
    UserProvidedBindings,
};

#[test]
fn assistant_template_keeps_portable_agent_slots() {
    let template = AgentTemplate::assistant_default();

    assert!(template.requires_slot(AgentSlotKind::Persona));
    assert!(template.requires_slot(AgentSlotKind::Model));
    assert!(template.supports_slot(AgentSlotKind::Toolset));
    assert!(template.supports_slot(AgentSlotKind::Memory));
    assert!(template.supports_slot(AgentSlotKind::Voice));
}

#[test]
fn readiness_reports_missing_llm_slot_and_permission() {
    let resolver = AgentBuilderResolver::fixture_missing_model_and_calendar_permission();
    let report = resolver.readiness_for_template(&AgentTemplate::assistant_default());

    assert!(report.has_issue("model.missing"));
    assert!(report.has_issue("permission.calendar.missing"));
}

#[test]
fn finalized_agent_contains_a_portable_llm_slot() {
    let resolver = AgentBuilderResolver::fixture_with_openai_binding_request();
    let plan = resolver
        .create_plan(
            AgentBuilderInput::from_template(AgentTemplate::assistant_default()),
            &UserEnvironment::fixture_ready(),
        )
        .unwrap();

    let profile = resolver
        .finalize(plan, UserProvidedBindings::empty())
        .unwrap();

    assert_eq!(
        profile.llm_slot().unwrap().requirements().slot_id(),
        "slot.model.primary"
    );
    assert!(profile.readiness().has_issue("host_binding.missing"));
}

#[test]
fn builder_boundary_does_not_own_runtime_execution() {
    let sources = [
        include_str!("../../src/user_customization/agent_template.rs"),
        include_str!("../../src/user_customization/agent_profile.rs"),
        include_str!("../../src/user_customization/builder_resolver.rs"),
    ]
    .join("\n");

    for forbidden in ["ResolvedRunSnapshot", "InferenceRouter", "ProviderRegistry"] {
        assert!(!sources.contains(forbidden), "builder owns {forbidden}");
    }
}
