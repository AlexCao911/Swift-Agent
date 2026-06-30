use local_ios_agent_runtime::user_customization::{
    ComponentContent, ComponentKind, ComponentKindDTO, UserComponentVersionId,
};

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
fn component_kind_is_pinned_for_component_identity() {
    let mut catalog =
        local_ios_agent_runtime::user_customization::ComponentCatalogService::default();
    let id = catalog.create_draft(ComponentContent::prompt("v1"));

    let result = catalog.update_draft(id, ComponentContent::tool_recipe("search"));

    assert!(result.is_err());
    assert_eq!(catalog.component(id).unwrap().kind(), ComponentKind::Prompt);
    assert_eq!(
        catalog
            .component(id)
            .unwrap()
            .current_draft()
            .content_text(),
        "v1"
    );
}

#[test]
fn empty_prompt_component_is_invalid() {
    let report = local_ios_agent_runtime::user_customization::ComponentValidator::default()
        .validate(&ComponentContent::prompt(""));

    assert!(!report.is_valid);
    assert_eq!(report.issues[0].code, "prompt.empty");
}

#[test]
fn invalid_prompt_cannot_be_published() {
    let mut catalog =
        local_ios_agent_runtime::user_customization::ComponentCatalogService::default();
    let id = catalog.create_draft(ComponentContent::prompt(""));

    let result = catalog.publish(id);

    assert!(result.is_err());
    assert!(catalog.version(UserComponentVersionId(1)).is_none());
    assert!(catalog
        .component(id)
        .unwrap()
        .published_versions()
        .is_empty());
}

#[test]
fn voice_profile_dry_run_is_schema_only() {
    let report = local_ios_agent_runtime::user_customization::ComponentTestHarness::default()
        .dry_run(&ComponentContent::voice_profile("compact", "calm", "text"));

    assert!(report.validation.is_valid);
    assert!(report.runtime_effects.is_empty());
    assert_eq!(report.boundary, "schema_only");
}

#[test]
fn component_content_has_tagged_serde_fixture_for_each_v1_kind() {
    let fixtures: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "fixtures/user_component/component_content_v1.json"
    ))
    .unwrap();
    let expected_kinds = [
        "prompt",
        "persona",
        "instruction",
        "skill",
        "tool_recipe",
        "memory_profile",
        "voice_profile",
        "brain_preset",
    ];

    assert_eq!(fixtures.len(), expected_kinds.len());
    for (value, expected_kind) in fixtures.into_iter().zip(expected_kinds) {
        assert_eq!(value["kind"], expected_kind);
        let decoded = serde_json::from_value::<ComponentContent>(value).unwrap();
        assert_eq!(
            serde_json::to_value(decoded).unwrap()["kind"],
            expected_kind
        );
    }
}

#[test]
fn component_kind_dto_preserves_unknown_kind_values() {
    let decoded = serde_json::from_str::<ComponentKindDTO>(include_str!(
        "fixtures/user_component/unknown_component_kind.json"
    ))
    .unwrap();

    assert_eq!(
        decoded,
        ComponentKindDTO::Unknown("future_component".to_string())
    );
    assert_eq!(
        serde_json::to_string(&decoded).unwrap(),
        "\"future_component\""
    );
}
