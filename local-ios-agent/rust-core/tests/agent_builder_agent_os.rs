use local_ios_agent_runtime::user_customization::{
    AgentBuilderResolver, AgentProfileDraft, AgentProfileId, AgentProfileVersion, AgentSlotId,
    AgentSlotKind, AgentTemplate, ComponentBinding, ComponentSettings, UserComponentVersionId,
};

#[test]
fn template_declares_required_slots() {
    let template = AgentTemplate::assistant_default();

    assert!(template.requires_slot(AgentSlotKind::Persona));
    assert!(template.requires_slot(AgentSlotKind::Model));
}

#[test]
fn assistant_template_supports_customizable_agent_parts_without_runtime_state() {
    let template = AgentTemplate::assistant_default();

    assert!(template.supports_slot(AgentSlotKind::Instruction));
    assert!(template.supports_slot(AgentSlotKind::Toolset));
    assert!(template.supports_slot(AgentSlotKind::Memory));
    assert!(template.supports_slot(AgentSlotKind::Voice));
}

#[test]
fn agent_profile_binds_published_component_versions() {
    let template = AgentTemplate::assistant_default();
    let persona_slot_id = template
        .slot_id_for_kind(AgentSlotKind::Persona)
        .unwrap()
        .clone();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(ComponentBinding::persona(
        persona_slot_id,
        UserComponentVersionId(1),
    ));
    let profile = draft.publish().unwrap();

    assert_eq!(
        profile.bindings()[0].component_version_id(),
        UserComponentVersionId(1)
    );
    assert_eq!(profile.bindings()[0].slot_kind(), AgentSlotKind::Persona);
}

#[test]
fn agent_profile_publish_rejects_draft_component_binding() {
    let template = AgentTemplate::assistant_default();
    let persona_slot_id = template
        .slot_id_for_kind(AgentSlotKind::Persona)
        .unwrap()
        .clone();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(ComponentBinding::persona(
        persona_slot_id,
        UserComponentVersionId(0),
    ));

    let error = draft.publish().unwrap_err();

    assert!(error.to_string().contains("published component version"));
}

#[test]
fn agent_profile_carries_stable_identity_template_and_version() {
    let template = AgentTemplate::assistant_default();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    );
    let profile = draft.publish().unwrap();

    assert_eq!(profile.id().as_str(), "profile.research");
    assert_eq!(profile.version(), AgentProfileVersion::initial());
    assert_eq!(profile.template_id(), template.id());
    assert_eq!(profile.name(), "Research Assistant");
    assert!(profile.local_bindings().is_empty());
}

#[test]
fn component_binding_targets_stable_slot_id_and_settings() {
    let binding = ComponentBinding::new(
        AgentSlotId::new("slot.persona.primary"),
        AgentSlotKind::Persona,
        UserComponentVersionId(1),
        ComponentSettings::default().with_value("tone", "concise"),
    );

    assert_eq!(binding.slot_id().as_str(), "slot.persona.primary");
    assert_eq!(binding.settings().value("tone"), Some("concise"));
}

#[test]
fn agent_profile_exposes_read_only_binding_lookup_by_slot() {
    let template = AgentTemplate::assistant_default();
    let persona_slot_id = template
        .slot_id_for_kind(AgentSlotKind::Persona)
        .unwrap()
        .clone();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(ComponentBinding::persona(
        persona_slot_id.clone(),
        UserComponentVersionId(1),
    ));
    let profile = draft.publish().unwrap();

    assert_eq!(
        profile
            .binding_for_slot(&persona_slot_id)
            .unwrap()
            .component_version_id(),
        UserComponentVersionId(1)
    );
    assert_eq!(profile.bindings_for_kind(AgentSlotKind::Persona).len(), 1);
}

#[test]
fn template_exposes_stable_slot_ids_for_repeated_slot_resolution() {
    let template = AgentTemplate::assistant_default();

    assert_eq!(
        template
            .slot_id_for_kind(AgentSlotKind::Model)
            .unwrap()
            .as_str(),
        "slot.model.primary"
    );
    assert!(template.supports_slot_id(&AgentSlotId::new("slot.voice.primary")));
}

#[test]
fn readiness_reports_missing_model_and_permission_together() {
    let resolver = AgentBuilderResolver::fixture_missing_model_and_calendar_permission();
    let report = resolver.readiness_for_template(&AgentTemplate::assistant_default());

    assert!(report.has_issue("model.missing"));
    assert!(report.has_issue("permission.calendar.missing"));
    assert_eq!(report.issues().len(), 2);
}

#[test]
fn readiness_reports_missing_required_component_slot() {
    let resolver = AgentBuilderResolver::fixture_missing_persona_component();
    let report = resolver.readiness_for_template(&AgentTemplate::assistant_default());

    assert!(report.has_issue("component.persona.missing"));
}

#[test]
fn agent_builder_boundary_does_not_reference_run_snapshot_or_runtime_execution() {
    let builder_sources = [
        include_str!("../src/user_customization/agent_template.rs"),
        include_str!("../src/user_customization/agent_profile.rs"),
        include_str!("../src/user_customization/agent_slot.rs"),
        include_str!("../src/user_customization/builder_resolver.rs"),
        include_str!("../src/user_customization/readiness.rs"),
    ]
    .join("\n");

    for forbidden in [
        "ResolvedRunSnapshot",
        "RunSnapshot",
        "RuntimeExecutionService",
        "AgentPackageReader",
        "ToolExecutor",
        "InferenceBackend",
    ] {
        assert!(
            !builder_sources.contains(forbidden),
            "Agent Builder base layer must not reference {forbidden}"
        );
    }
}
