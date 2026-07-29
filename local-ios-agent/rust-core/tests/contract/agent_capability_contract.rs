use local_ios_agent_runtime::context::{
    ContextAssembler, ContextContribution, ContextContributionBundle, ContextSegment,
    ModelInputRole,
};
use local_ios_agent_runtime::tool::{
    HostPlatform, ToolCapabilityDescriptor, ToolSchema, ToolSchemaMetadata,
};
use local_ios_agent_runtime::user_customization::{
    ComponentContent, InMemorySkillRepository, SkillActivationInput, SkillPackage,
    SkillPackageManifest, SkillRepository,
};

#[test]
fn skill_package_declares_capabilities_without_executable_runtime() {
    let skill = SkillPackage::new(
        SkillPackageManifest::new("skill.research", "1.0.0", "Research Assistant")
            .with_description("Plan and run research workflows")
            .requires_capability("capability.web_search")
            .requires_capability("capability.document_read")
            .allows_capability("capability.memory.write"),
        "Use available sources, cite uncertainty, and ask before writing memory.",
    );

    assert_eq!(skill.manifest().id(), "skill.research");
    assert_eq!(
        skill.manifest().required_capabilities(),
        &["capability.web_search", "capability.document_read"]
    );
    assert_eq!(
        skill.instructions_markdown(),
        "Use available sources, cite uncertainty, and ask before writing memory."
    );
    assert!(!skill.sandbox_policy().allows_executable_code());
    assert!(skill
        .sandbox_policy()
        .allows_capability("capability.memory.write"));
}

#[test]
fn skill_activation_produces_context_contribution_segments() {
    let skill = SkillPackage::new(
        SkillPackageManifest::new("skill.calendar_planning", "1.0.0", "Calendar Planning")
            .requires_capability("capability.calendar.read"),
        "When scheduling, inspect existing commitments before suggesting times.",
    );

    let activation = skill.activate(SkillActivationInput::new("run_1"));

    assert_eq!(activation.skill_id(), "skill.calendar_planning");
    assert_eq!(activation.reason(), "skill.activation.manual");
    assert_eq!(activation.context_contributions().segments().len(), 1);
    assert_eq!(
        activation.context_contributions().segments()[0]
            .id()
            .as_str(),
        "skill.skill.calendar_planning.instructions"
    );
}

#[test]
fn skill_repository_installs_and_resolves_packages_by_manifest_id() {
    let mut repository = InMemorySkillRepository::default();
    let skill = SkillPackage::new(
        SkillPackageManifest::new("skill.writing", "1.0.0", "Writing")
            .requires_capability("capability.document_read"),
        "Rewrite with care and preserve user intent.",
    );

    repository.install(skill).unwrap();

    assert_eq!(repository.list().len(), 1);
    assert_eq!(
        repository.get("skill.writing").unwrap().manifest().title(),
        "Writing"
    );
    assert!(repository.get("skill.missing").is_none());
}

#[test]
fn skill_component_content_carries_package_manifest_without_runtime_wiring() {
    let content = ComponentContent::skill_package(
        SkillPackageManifest::new("skill.research", "1.2.0", "Research")
            .requires_capability("capability.web_search")
            .allows_capability("capability.memory.write"),
        "Search carefully and keep citations in context.",
    );

    let ComponentContent::Skill(skill) = content else {
        panic!("expected skill component content");
    };

    assert_eq!(skill.manifest().id(), "skill.research");
    assert_eq!(skill.manifest().version(), "1.2.0");
    assert_eq!(
        skill.manifest().required_capabilities(),
        &["capability.web_search"]
    );
    assert_eq!(
        skill.instructions_markdown(),
        "Search carefully and keep citations in context."
    );
}

#[test]
fn tool_schema_metadata_declares_cross_platform_capability() {
    let schema = ToolSchema {
        name: "calendar.search_events".to_string(),
        description: "Search calendar events".to_string(),
        parameters_json_schema: r#"{"type":"object"}"#.to_string(),
        risk_level: local_ios_agent_runtime::security::RiskLevel::ReadOnly,
        metadata_json: None,
    }
    .with_metadata(
        ToolSchemaMetadata::new().with_capability(
            ToolCapabilityDescriptor::new("capability.calendar.read")
                .with_permission_scope("calendar.events")
                .available_on(HostPlatform::Ios)
                .available_on(HostPlatform::MacOs),
        ),
    );

    assert!(schema.provides_capability("capability.calendar.read"));
    let metadata = schema.typed_metadata().unwrap();
    assert_eq!(
        metadata.capabilities()[0].permission_scope(),
        Some("calendar.events")
    );
    assert_eq!(
        metadata.capabilities()[0].platforms(),
        &[HostPlatform::Ios, HostPlatform::MacOs]
    );
}

#[test]
fn context_contribution_bundle_keeps_skill_and_memory_segments_structured() {
    let bundle = ContextContributionBundle::new()
        .with_contribution(ContextContribution::new(
            "skill.research",
            ContextSegment::skill_instruction(
                "skill.research.instructions",
                "Use careful source evaluation.",
            )
            .with_model_role(ModelInputRole::System),
        ))
        .with_contribution(ContextContribution::new(
            "memory.selected",
            ContextSegment::memory(
                "memory.user.prefers_concise",
                "User prefers concise answers.",
            ),
        ));

    let input = ContextAssembler::new()
        .with_contributions(bundle)
        .assemble_default()
        .unwrap()
        .model_input_messages();

    assert_eq!(input.messages().len(), 2);
    assert_eq!(
        input.messages()[0].source_segment_id(),
        "skill.research.instructions"
    );
    assert_eq!(
        input.messages()[1].source_segment_id(),
        "memory.user.prefers_concise"
    );
}
