use local_ios_agent_runtime::llm_contracts::{AgentLLMRequirements, LLMSlotV2, LLMToolCallingMode};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::{
    AgentProfileDraft, AgentProfileId, AgentProfilePublisher, AgentSlotKind, AgentTemplate,
    ComponentBinding, ComponentCatalogService, ComponentContent, InMemoryAgentProfileRepository,
};

fn portable_slot() -> LLMSlotV2 {
    LLMSlotV2::new(AgentLLMRequirements::new(
        "slot.model.primary",
        8_192,
        true,
        LLMToolCallingMode::Allowed,
    ))
}

#[test]
fn profile_publishes_component_versions_and_portable_llm_slot() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let component = catalog.create_draft(ComponentContent::persona("Research persona"));
    let persona_version = catalog.publish(component).unwrap();
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
    .bind(ComponentBinding::persona(
        template
            .slot_id_for_kind(AgentSlotKind::Persona)
            .unwrap()
            .clone(),
        persona_version,
    ))
    .with_llm_slot(portable_slot());

    let reference = publisher.publish(draft, &template, &catalog).unwrap();
    let profile = repository.profile(&reference).unwrap();

    assert_eq!(
        profile.bindings()[0].component_version_id(),
        persona_version
    );
    assert_eq!(
        profile.llm_slot().unwrap().requirements().slot_id(),
        "slot.model.primary"
    );
    assert!(profile.readiness().has_issue("host_binding.missing"));
}

#[test]
fn profile_publish_rejects_missing_required_llm_slot() {
    let template = AgentTemplate::assistant_default();
    let catalog = ComponentCatalogService::default();
    let component = catalog.create_draft(ComponentContent::persona("Research persona"));
    let persona_version = catalog.publish(component).unwrap();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        InMemoryAgentProfileRepository::default(),
    );
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.incomplete"),
        template.id().clone(),
        "Incomplete",
    )
    .bind(ComponentBinding::persona(
        template
            .slot_id_for_kind(AgentSlotKind::Persona)
            .unwrap()
            .clone(),
        persona_version,
    ));

    let error = publisher.publish(draft, &template, &catalog).unwrap_err();

    assert_eq!(error.code(), "agent_profile.required_slot_missing");
}

#[test]
fn profile_publish_rejects_unknown_component_version() {
    let template = AgentTemplate::assistant_default();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        InMemoryAgentProfileRepository::default(),
    );
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.unknown"),
        template.id().clone(),
        "Unknown",
    )
    .bind(ComponentBinding::persona(
        template
            .slot_id_for_kind(AgentSlotKind::Persona)
            .unwrap()
            .clone(),
        local_ios_agent_runtime::user_customization::UserComponentVersionId::new(99),
    ))
    .with_llm_slot(portable_slot());

    let error = publisher
        .publish(draft, &template, &ComponentCatalogService::default())
        .unwrap_err();

    assert_eq!(error.code(), "agent_profile.component_version_missing");
}
