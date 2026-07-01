use local_ios_agent_runtime::model::{
    ModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::{
    AgentBuilderResolver, AgentProfileDraft, AgentProfileId, AgentProfileModelBinding,
    AgentProfilePublisher, AgentProfileVersion, AgentSlotId, AgentSlotKind, AgentTemplate,
    ComponentBinding, ComponentCatalogService, ComponentContent, ComponentSettings,
    InMemoryAgentProfileRepository, UserComponentVersionId,
};

fn publish_persona_version(catalog: &ComponentCatalogService) -> UserComponentVersionId {
    let component_id = catalog.create_draft(ComponentContent::persona("Research persona"));
    catalog.publish(component_id).unwrap()
}

fn primary_persona_binding(
    template: &AgentTemplate,
    version_id: UserComponentVersionId,
) -> ComponentBinding {
    ComponentBinding::persona(
        template
            .slot_id_for_kind(AgentSlotKind::Persona)
            .unwrap()
            .clone(),
        version_id,
    )
}

fn primary_model_binding(template: &AgentTemplate) -> AgentProfileModelBinding {
    AgentProfileModelBinding::new(
        template
            .slot_id_for_kind(AgentSlotKind::Model)
            .unwrap()
            .clone(),
        primary_model_selection(),
    )
}

fn primary_model_catalog() -> ModelBindingCatalog {
    ModelBindingCatalog::default().with_selection(primary_model_selection())
}

fn primary_model_selection() -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        "gpt-4.1-mini",
        ModelCatalogVersion::new(7),
    )
}

#[test]
fn model_binding_catalog_rejects_duplicate_binding_ids() {
    let catalog = ModelBindingCatalog::default()
        .try_with_selection(primary_model_selection())
        .unwrap();
    let duplicate = ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.other",
        "provider.other",
        "other-model",
        ModelCatalogVersion::new(8),
    );

    let error = catalog.try_with_selection(duplicate).unwrap_err();

    assert_eq!(error.code(), "model_binding_catalog.duplicate_binding_id");
}

#[test]
fn model_binding_catalog_rejects_non_pinnable_selection() {
    let selection = ModelSelection::new(
        ModelBindingId::new("model_binding.blank"),
        "account.openai.default",
        "  ",
        "",
        ModelCatalogVersion::new(7),
    );

    let error = ModelBindingCatalog::default()
        .try_with_selection(selection)
        .unwrap_err();

    assert_eq!(error.code(), "model_binding_catalog.selection_not_pinnable");
}

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
    let catalog = ComponentCatalogService::default();
    let version_id = publish_persona_version(&catalog);
    let repository = InMemoryAgentProfileRepository::default();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        repository.clone(),
    );
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(primary_persona_binding(&template, version_id))
    .with_model_binding(primary_model_binding(&template));
    let model_catalog = primary_model_catalog();
    let reference = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap();
    let profile = repository.profile(&reference).unwrap();

    assert_eq!(profile.bindings()[0].component_version_id(), version_id);
    assert_eq!(profile.bindings()[0].slot_kind(), AgentSlotKind::Persona);
}

#[test]
fn agent_profile_publishes_model_binding_for_required_model_slot() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let version_id = publish_persona_version(&catalog);
    let repository = InMemoryAgentProfileRepository::default();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        repository.clone(),
    );
    let model_slot_id = template
        .slot_id_for_kind(AgentSlotKind::Model)
        .unwrap()
        .clone();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(primary_persona_binding(&template, version_id))
    .with_model_binding(AgentProfileModelBinding::new(
        model_slot_id.clone(),
        ModelSelection::new(
            ModelBindingId::new("model_binding.primary"),
            "account.openai.default",
            "provider.openai",
            "gpt-4.1-mini",
            ModelCatalogVersion::new(7),
        ),
    ));

    let model_catalog = primary_model_catalog();
    let reference = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap();
    let profile = repository.profile(&reference).unwrap();

    let model_binding = profile.model_binding().unwrap();
    assert_eq!(model_binding.slot_id(), &model_slot_id);
    assert_eq!(model_binding.selection().model_id(), "gpt-4.1-mini");
    assert_eq!(
        model_binding.selection().provider_account_id(),
        "account.openai.default"
    );
    assert_eq!(
        model_binding.selection().catalog_version(),
        ModelCatalogVersion::new(7)
    );
}

#[test]
fn agent_profile_publish_rejects_unknown_model_selection() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let version_id = publish_persona_version(&catalog);
    let repository = InMemoryAgentProfileRepository::default();
    let publisher =
        AgentProfilePublisher::new(Box::new(InMemoryTransactionRunner::default()), repository);
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(primary_persona_binding(&template, version_id))
    .with_model_binding(primary_model_binding(&template));
    let empty_model_catalog = ModelBindingCatalog::default();

    let error = publisher
        .publish(draft, &template, &catalog, &empty_model_catalog)
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.model_binding_missing");
}

#[test]
fn agent_profile_publish_rejects_missing_required_model_slot() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let version_id = publish_persona_version(&catalog);
    let repository = InMemoryAgentProfileRepository::default();
    let publisher =
        AgentProfilePublisher::new(Box::new(InMemoryTransactionRunner::default()), repository);
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(primary_persona_binding(&template, version_id));

    let model_catalog = primary_model_catalog();
    let error = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.required_slot_missing");
}

#[test]
fn agent_profile_publish_rejects_duplicate_component_slot_binding() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let first_version_id = publish_persona_version(&catalog);
    let second_component_id = catalog.create_draft(ComponentContent::persona("Second persona"));
    let second_version_id = catalog.publish(second_component_id).unwrap();
    let repository = InMemoryAgentProfileRepository::default();
    let publisher =
        AgentProfilePublisher::new(Box::new(InMemoryTransactionRunner::default()), repository);
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
        first_version_id,
    ))
    .bind(ComponentBinding::persona(
        persona_slot_id,
        second_version_id,
    ))
    .with_model_binding(primary_model_binding(&template));

    let model_catalog = primary_model_catalog();
    let error = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.duplicate_slot_binding");
}

#[test]
fn agent_profile_publish_rejects_draft_component_binding() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let repository = InMemoryAgentProfileRepository::default();
    let publisher =
        AgentProfilePublisher::new(Box::new(InMemoryTransactionRunner::default()), repository);
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

    let model_catalog = primary_model_catalog();
    let error = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.component_version_unpublished");
}

#[test]
fn agent_profile_carries_stable_identity_template_and_version() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let version_id = publish_persona_version(&catalog);
    let repository = InMemoryAgentProfileRepository::default();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        repository.clone(),
    );
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(primary_persona_binding(&template, version_id))
    .with_model_binding(primary_model_binding(&template));
    let model_catalog = primary_model_catalog();
    let reference = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap();
    let profile = repository.profile(&reference).unwrap();

    assert_eq!(profile.id().as_str(), "profile.research");
    assert_eq!(profile.version(), AgentProfileVersion::initial());
    assert_eq!(profile.template_id(), template.id());
    assert_eq!(profile.name(), "Research Assistant");
    assert!(profile.local_bindings().is_empty());
    assert!(profile.model_binding().is_some());
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
fn user_component_binding_maps_to_protocol_binding_explicitly() {
    let binding = ComponentBinding::persona(
        AgentSlotId::new("slot.persona.primary"),
        UserComponentVersionId(7),
    );

    let protocol_binding = binding.to_protocol_binding();

    assert_eq!(protocol_binding.slot_key().as_str(), "slot.persona.primary");
    assert_eq!(
        protocol_binding.instance_id().as_str(),
        "component_version.7"
    );
    assert_eq!(
        protocol_binding.id().as_str(),
        "binding.slot.persona.primary.component_version.7"
    );
}

#[test]
fn agent_profile_exposes_read_only_binding_lookup_by_slot() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let version_id = publish_persona_version(&catalog);
    let repository = InMemoryAgentProfileRepository::default();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        repository.clone(),
    );
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
        version_id,
    ))
    .with_model_binding(primary_model_binding(&template));
    let model_catalog = primary_model_catalog();
    let reference = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap();
    let profile = repository.profile(&reference).unwrap();

    assert_eq!(
        profile
            .binding_for_slot(&persona_slot_id)
            .unwrap()
            .component_version_id(),
        version_id
    );
    assert_eq!(profile.bindings_for_kind(AgentSlotKind::Persona).len(), 1);
}

#[test]
fn agent_profile_publisher_rejects_missing_component_version() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let repository = InMemoryAgentProfileRepository::default();
    let publisher =
        AgentProfilePublisher::new(Box::new(InMemoryTransactionRunner::default()), repository);
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
        UserComponentVersionId(42),
    ));

    let model_catalog = primary_model_catalog();
    let error = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.component_version_missing");
}

#[test]
fn agent_profile_publisher_rejects_binding_for_slot_outside_template() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let component_id = catalog.create_draft(ComponentContent::persona("Research persona"));
    let version_id = catalog.publish(component_id).unwrap();
    let repository = InMemoryAgentProfileRepository::default();
    let publisher =
        AgentProfilePublisher::new(Box::new(InMemoryTransactionRunner::default()), repository);
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    )
    .bind(ComponentBinding::persona(
        AgentSlotId::new("slot.persona.unknown"),
        version_id,
    ));

    let model_catalog = primary_model_catalog();
    let error = publisher
        .publish(draft, &template, &catalog, &model_catalog)
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.slot_unsupported");
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
fn readiness_for_draft_uses_actual_bindings_instead_of_fixture_booleans() {
    let template = AgentTemplate::assistant_default();
    let resolver = AgentBuilderResolver::fixture_missing_persona_component();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.research"),
        template.id().clone(),
        "Research Assistant",
    );

    let report = resolver.readiness_for_draft(&draft, &template);

    assert!(report.has_issue("component.persona.missing"));
    assert!(report.has_issue("model.missing"));
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
