use local_ios_agent_runtime::model::{
    ModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::{
    AgentProfileDraft, AgentProfileId, AgentProfileModelBinding, AgentProfilePublisher,
    AgentProfileReference, AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService,
    ComponentContent, InMemoryAgentProfileRepository, UserComponentVersionId,
};

fn publish_persona_version(catalog: &ComponentCatalogService) -> UserComponentVersionId {
    let component_id = catalog.create_draft(ComponentContent::persona("Research persona"));
    catalog.publish(component_id).unwrap()
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

fn primary_model_catalog() -> ModelBindingCatalog {
    ModelBindingCatalog::default().with_selection(primary_model_selection())
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

fn persona_binding(
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

fn publisher_with_repository() -> (AgentProfilePublisher, InMemoryAgentProfileRepository) {
    let repository = InMemoryAgentProfileRepository::default();
    (
        AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            repository.clone(),
        ),
        repository,
    )
}

fn assert_profile_not_persisted(repository: &InMemoryAgentProfileRepository, profile_id: &str) {
    assert!(
        repository
            .profile(&AgentProfileReference::latest(AgentProfileId::new(
                profile_id
            )))
            .is_none(),
        "failed profile publish must not persist {profile_id}"
    );
}

#[test]
fn profile_publish_rejects_missing_required_slots_without_persisting_profile() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let (publisher, repository) = publisher_with_repository();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.incomplete"),
        template.id().clone(),
        "Incomplete",
    );

    let error = publisher
        .publish(draft, &template, &catalog, &primary_model_catalog())
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.required_slot_missing");
    assert_profile_not_persisted(&repository, "profile.incomplete");
}

#[test]
fn profile_publish_rejects_duplicate_component_slot_bindings_without_persisting_profile() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let first_version = publish_persona_version(&catalog);
    let second_version = publish_persona_version(&catalog);
    let (publisher, repository) = publisher_with_repository();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.duplicate-slot"),
        template.id().clone(),
        "Duplicate Slot",
    )
    .bind(persona_binding(&template, first_version))
    .bind(persona_binding(&template, second_version))
    .with_model_binding(primary_model_binding(&template));

    let error = publisher
        .publish(draft, &template, &catalog, &primary_model_catalog())
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.duplicate_slot_binding");
    assert_profile_not_persisted(&repository, "profile.duplicate-slot");
}

#[test]
fn profile_publish_rejects_unknown_component_version_without_persisting_profile() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let (publisher, repository) = publisher_with_repository();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.unknown-component"),
        template.id().clone(),
        "Unknown Component",
    )
    .bind(persona_binding(&template, UserComponentVersionId::new(999)))
    .with_model_binding(primary_model_binding(&template));

    let error = publisher
        .publish(draft, &template, &catalog, &primary_model_catalog())
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.component_version_missing");
    assert_profile_not_persisted(&repository, "profile.unknown-component");
}

#[test]
fn profile_publish_rejects_model_selection_not_present_in_catalog_without_persisting_profile() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let persona_version = publish_persona_version(&catalog);
    let (publisher, repository) = publisher_with_repository();
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.unknown-model"),
        template.id().clone(),
        "Unknown Model",
    )
    .bind(persona_binding(&template, persona_version))
    .with_model_binding(primary_model_binding(&template));

    let error = publisher
        .publish(draft, &template, &catalog, &ModelBindingCatalog::default())
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.model_binding_missing");
    assert_profile_not_persisted(&repository, "profile.unknown-model");
}
