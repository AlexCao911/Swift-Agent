use local_ios_agent_runtime::user_customization::{
    AgentAssemblyPlan, AgentBuilderInput, AgentBuilderResolver, AgentProfile, AgentTemplate,
    AssemblyWarning, BindingRequest, ComponentGraph, ComponentGraphBuilder, ComponentNode,
    MissingRequirement, SafetyReview, SettingsControlKind, UserEnvironment, UserFacingCapabilityId,
    UserProvidedBindings, UserSettingsSchema,
};

#[test]
fn graph_reports_missing_required_tool_capability() {
    let web_search = UserFacingCapabilityId::new("capability.web_search");
    let skill = ComponentNode::skill("skill.research", 1).requires(web_search.clone());
    let graph = ComponentGraphBuilder::default().add_node(skill).build();

    let report = graph.validate_capabilities();

    assert!(report.has_missing_capability("skill.research", "capability.web_search"));
    assert_eq!(
        report.blocking_issue_codes(),
        vec!["capability.required.missing"]
    );
}

#[test]
fn graph_links_required_capability_to_provider() {
    let web_search = UserFacingCapabilityId::new("capability.web_search");
    let skill = ComponentNode::skill("skill.research", 1).requires(web_search.clone());
    let tool = ComponentNode::tool_recipe("tool.web_search", 2).provides(web_search);
    let graph = ComponentGraphBuilder::default()
        .add_node(skill)
        .add_node(tool)
        .build();

    let report = graph.validate_capabilities();

    assert!(report.is_ready());
    assert_eq!(graph.edges()[0].from().as_str(), "skill.research");
    assert_eq!(graph.edges()[0].to().as_str(), "tool.web_search");
}

#[test]
fn assembly_plan_contains_readiness_bindings_warnings_and_safety_review() {
    let plan = AgentAssemblyPlan::new(ComponentGraph::fixture_missing_model())
        .missing(MissingRequirement::model("slot.model.primary"))
        .binding(BindingRequest::credential(
            "provider.openai",
            "credential.openai.api_key",
        ))
        .warning(AssemblyWarning::requires_approval("tool.calendar.write"))
        .with_safety_review(SafetyReview::fixture_high_egress_risk());

    assert!(plan.readiness_report().has_issue("model.missing"));
    assert!(plan
        .required_bindings()
        .iter()
        .any(|binding| binding.binding_key() == "credential.openai.api_key"));
    assert!(plan.safety_review().requires_user_review());
}

#[test]
fn create_plan_expands_template_and_blocks_missing_tool_capability() {
    let resolver = AgentBuilderResolver::fixture_catalog_without_web_search_tool();
    let input = AgentBuilderInput::from_template(AgentTemplate::research_assistant());
    let plan = resolver
        .create_plan(input, &UserEnvironment::fixture_ready_except_tools())
        .unwrap();

    assert!(plan.component_graph().has_node("skill.research"));
    assert!(plan
        .readiness_report()
        .has_issue("capability.required.missing"));
    assert!(plan
        .missing_requirements()
        .iter()
        .any(|item| item.code() == "tool.capability.missing"));
}

#[test]
fn create_plan_does_not_inject_research_skill_for_default_assistant_template() {
    let resolver = AgentBuilderResolver::fixture_with_openai_binding_request();
    let input = AgentBuilderInput::from_template(AgentTemplate::assistant_default());
    let plan = resolver
        .create_plan(input, &UserEnvironment::fixture_ready())
        .unwrap();

    assert!(!plan.component_graph().has_node("skill.research"));
}

#[test]
fn create_plan_flags_remote_model_for_safety_review() {
    let resolver = AgentBuilderResolver::fixture_with_openai_binding_request();
    let input = AgentBuilderInput::from_template(AgentTemplate::research_assistant());
    let plan = resolver
        .create_plan(input, &UserEnvironment::fixture_ready())
        .unwrap();

    assert!(plan.safety_review().requires_user_review());
}

#[test]
fn settings_schema_exposes_safe_renderer_descriptors() {
    let schema = UserSettingsSchema::fixture_generation_controls();

    assert_eq!(
        schema.field("temperature").unwrap().control(),
        SettingsControlKind::Slider
    );
    assert_eq!(
        schema.field("model").unwrap().control(),
        SettingsControlKind::Picker
    );
    assert!(!schema.serialized_text().contains("api_key"));
    assert!(!schema.serialized_text().contains("/Users/"));
}

#[test]
fn settings_schema_drops_secret_like_and_local_path_defaults() {
    let schema = UserSettingsSchema::new(vec![
        local_ios_agent_runtime::user_customization::SettingsFieldDescriptor::picker(
            "api_key",
            "API key",
            vec![],
        )
        .with_default("sk-test-secret"),
        local_ios_agent_runtime::user_customization::SettingsFieldDescriptor::picker(
            "model_path",
            "Model path",
            vec![],
        )
        .with_default("/Users/alex/private/model.gguf"),
    ]);

    assert!(!schema.serialized_text().contains("sk-test-secret"));
    assert!(!schema.serialized_text().contains("/Users/alex"));
    assert_eq!(schema.field("api_key").unwrap().default_value(), None);
    assert_eq!(schema.field("model_path").unwrap().default_value(), None);
}

#[test]
fn finalize_rejects_unresolved_required_binding() {
    let resolver = AgentBuilderResolver::fixture_with_openai_binding_request();
    let plan = resolver.fixture_plan_with_openai_binding_request();
    let error = resolver
        .finalize(plan, UserProvidedBindings::empty())
        .unwrap_err();

    assert_eq!(error.code(), "binding.required.unresolved");
}

#[test]
fn finalize_publishes_profile_with_component_versions_and_bindings() {
    let resolver = AgentBuilderResolver::fixture_with_openai_binding_request();
    let plan = resolver.fixture_plan_with_openai_binding_request();
    let bindings = UserProvidedBindings::default()
        .credential("credential.openai.api_key", "credential_ref.openai.default");

    let profile: AgentProfile = resolver.finalize(plan, bindings).unwrap();

    assert!(profile
        .bindings()
        .iter()
        .all(|binding| binding.component_version_id().is_published()));
    assert_eq!(
        profile
            .local_bindings()
            .credential_ref("credential.openai.api_key"),
        Some("credential_ref.openai.default")
    );
}

#[test]
fn finalize_rejects_profile_draft_with_unknown_component_version() {
    let resolver = AgentBuilderResolver::fixture_with_missing_component_catalog_entry();
    let plan = resolver.fixture_plan_with_openai_binding_request();
    let bindings = UserProvidedBindings::default()
        .credential("credential.openai.api_key", "credential_ref.openai.default");

    let error = resolver.finalize(plan, bindings).unwrap_err();

    assert_eq!(error.code(), "agent_profile.component_version_missing");
}

#[test]
fn finalize_rejects_profile_draft_with_unknown_model_selection() {
    let resolver = AgentBuilderResolver::fixture_with_missing_model_catalog_entry();
    let plan = resolver.fixture_plan_with_openai_binding_request();
    let bindings = UserProvidedBindings::default()
        .credential("credential.openai.api_key", "credential_ref.openai.default");

    let error = resolver.finalize(plan, bindings).unwrap_err();

    assert_eq!(error.code(), "agent_profile.model_binding_missing");
}
