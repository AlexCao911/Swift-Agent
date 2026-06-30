use local_ios_agent_runtime::user_customization::{ComponentContent, ComponentKind};

#[test]
fn v1_component_content_has_closed_taxonomy() {
    assert_eq!(
        ComponentContent::prompt("Be concise").kind(),
        ComponentKind::Prompt
    );
    assert_eq!(
        ComponentContent::persona("Researcher").kind(),
        ComponentKind::Persona
    );
    assert_eq!(
        ComponentContent::tool_recipe("search").kind(),
        ComponentKind::ToolRecipe
    );
}

#[test]
fn publishing_component_pins_immutable_version() {
    let mut catalog =
        local_ios_agent_runtime::user_customization::ComponentCatalogService::default();
    let id = catalog.create_draft(ComponentContent::prompt("v1"));
    let version = catalog.publish(id).unwrap();
    catalog
        .update_draft(id, ComponentContent::prompt("v2"))
        .unwrap();

    assert_eq!(catalog.version(version).unwrap().content_text(), "v1");
}

#[test]
fn empty_prompt_component_is_invalid() {
    let report = local_ios_agent_runtime::user_customization::ComponentValidator::default()
        .validate(&ComponentContent::prompt(""));

    assert!(!report.is_valid);
    assert_eq!(report.issues[0].code, "prompt.empty");
}

#[test]
fn voice_profile_dry_run_is_schema_only() {
    let report = local_ios_agent_runtime::user_customization::ComponentTestHarness::default()
        .dry_run(&ComponentContent::voice_profile("compact", "calm", "text"));

    assert!(report.validation.is_valid);
    assert!(report.runtime_effects.is_empty());
    assert_eq!(report.boundary, "schema_only");
}
