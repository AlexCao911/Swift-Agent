use std::sync::Arc;

use local_ios_agent_runtime::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::llm_contracts::{
    AgentLLMRequirements, LLMInputModality, LLMToolCallingMode,
};
use local_ios_agent_runtime::storage::{SqliteRuntimeStateStore, UnifiedRuntimeStateRepository};
use local_ios_agent_runtime::user_customization::{AgentProfileId, AgentProfileVersion};

#[test]
fn v2_profile_and_components_reopen_from_agent_sqlite() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let first = SqliteRuntimeStateStore::open(&path).unwrap();
    let service = AgentOSApplicationService::from_runtime_state(
        AgentOSApplicationServiceConfig::new(),
        Arc::new(first.clone()),
    )
    .unwrap();
    let profile = service
        .build_agent_v2(
            "publish-profile-a-1",
            Some("profile-a"),
            "template.assistant.default",
            AgentBuilderCardDraftInput {
                display_name: Some("Durable Agent".into()),
                persona: Some("Careful".into()),
                ..AgentBuilderCardDraftInput::default()
            },
            AgentLLMRequirements::new(
                "slot.model.primary",
                16_384,
                true,
                LLMToolCallingMode::Allowed,
            )
            .requiring_input_modality(LLMInputModality::Text),
        )
        .unwrap();
    let replayed = service
        .build_agent_v2(
            "publish-profile-a-1",
            Some("profile-a"),
            "template.assistant.default",
            AgentBuilderCardDraftInput {
                display_name: Some("Changed only after an ambiguous reply".into()),
                persona: Some("Different".into()),
                ..AgentBuilderCardDraftInput::default()
            },
            AgentLLMRequirements::new(
                "slot.model.primary",
                4_096,
                true,
                LLMToolCallingMode::Disabled,
            ),
        )
        .unwrap();
    assert_eq!(replayed, profile);
    let component_id = profile.bindings()[0].component_version_id();
    drop(service);
    drop(first);

    let reopened = SqliteRuntimeStateStore::open(&path).unwrap();
    let loaded = reopened
        .agent_profile_exact(
            &AgentProfileId::new("profile-a"),
            AgentProfileVersion::new(1),
        )
        .unwrap()
        .expect("persisted profile must exist");

    assert_eq!(loaded, profile);
    assert!(loaded.llm_slot().is_some());
    assert!(reopened
        .agent_component_exact(component_id)
        .unwrap()
        .is_some());
}
