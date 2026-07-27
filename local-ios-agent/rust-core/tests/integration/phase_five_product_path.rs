use std::sync::Arc;

use local_ios_agent_runtime::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::llm_contracts::{
    BeginLegacyProfileMigration, LLMBindingSchema, LegacyProfileMigrationService,
};
use local_ios_agent_runtime::migration::LegacyAgentProfileTranslator;
use local_ios_agent_runtime::storage::{
    InMemoryRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use local_ios_agent_runtime::user_customization::{
    AgentProfileId, AgentProfileVersion, AgentSlotKind,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct MigrationFixture {
    profile_id: String,
    display_name: String,
    target_family: String,
    selected_tool_ids: Vec<String>,
    context_step_ids: Vec<String>,
    expected_model_hint: String,
}

#[test]
fn recognized_legacy_fixtures_expose_provider_neutral_actions() {
    for (name, expected_family) in [
        ("legacy-local-profile.json", "local"),
        ("legacy-cloud-profile.json", "cloud"),
        ("legacy-mock-profile.json", "mock"),
    ] {
        let fixture = fixture(name);
        assert_eq!(fixture.target_family, expected_family);
        let (app, repository) = app_from_fixture(&fixture);
        let migration = LegacyProfileMigrationService::new(repository.clone());

        let actions = migration.actions().unwrap();

        assert_eq!(actions.len(), 1);
        assert_eq!(
            actions[0].migration_subject(),
            format!("{}:1", fixture.profile_id)
        );
        assert_eq!(actions[0].display_name(), fixture.display_name);
        assert_eq!(
            actions[0].redacted_model_hint(),
            Some(fixture.expected_model_hint.as_str())
        );
        assert!(actions[0].successor().is_none());
        assert_eq!(
            app.snapshot_service()
                .profile_execution_route(
                    &AgentProfileId::new(&fixture.profile_id),
                    AgentProfileVersion::new(1),
                )
                .unwrap()
                .llm_binding_schema(),
            LLMBindingSchema::LegacyV1
        );
    }
}

#[test]
fn direct_upgrade_preserves_the_complete_published_profile_graph() {
    let fixture = fixture("direct-upgrade-complete-profile.json");
    let (_app, repository) = app_from_fixture(&fixture);
    let source = exact(&repository, &fixture.profile_id, 1);
    let translated = LegacyAgentProfileTranslator::translate_known_profile(&source).unwrap();
    let migration = LegacyProfileMigrationService::new(repository.clone());

    let actions = migration.actions().unwrap();
    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "direct-upgrade",
            &fixture.profile_id,
            1,
        ))
        .unwrap();

    assert_eq!(actions.len(), 1);
    assert_eq!(translated.component_bindings(), source.bindings());
    assert!(translated.has_component_kind(AgentSlotKind::Persona));
    assert!(translated.has_component_kind(AgentSlotKind::Instruction));
    assert!(translated.has_component_kind(AgentSlotKind::Toolset));
    assert_eq!(
        exact(&repository, &fixture.profile_id, 1),
        source,
        "migration must not rewrite the runnable V1 source"
    );
    let successor = action.successor().unwrap();
    assert_eq!(
        exact(&repository, successor.profile_id(), successor.profile_revision()).bindings(),
        source.bindings()
    );
    assert_eq!(migration.records().unwrap().len(), 1);
}

fn fixture(name: &str) -> MigrationFixture {
    let source = match name {
        "legacy-local-profile.json" => {
            include_str!("../fixtures/migration/legacy-local-profile.json")
        }
        "legacy-cloud-profile.json" => {
            include_str!("../fixtures/migration/legacy-cloud-profile.json")
        }
        "legacy-mock-profile.json" => {
            include_str!("../fixtures/migration/legacy-mock-profile.json")
        }
        "direct-upgrade-complete-profile.json" => {
            include_str!("../fixtures/migration/direct-upgrade-complete-profile.json")
        }
        _ => panic!("unknown migration fixture"),
    };
    serde_json::from_str(source).unwrap()
}

fn app_from_fixture(
    fixture: &MigrationFixture,
) -> (
    AgentOSApplicationService,
    Arc<dyn UnifiedRuntimeStateRepository>,
) {
    let repository: Arc<dyn UnifiedRuntimeStateRepository> =
        Arc::new(InMemoryRuntimeStateStore::new());
    let app = AgentOSApplicationService::from_runtime_state(
        AgentOSApplicationServiceConfig::new(),
        repository.clone(),
    )
    .unwrap();
    app.build_agent_from_template(
        Some(&fixture.profile_id),
        "template.assistant.default",
        AgentBuilderCardDraftInput {
            display_name: Some(fixture.display_name.clone()),
            persona: Some("Migration fixture".into()),
            system_prompt: Some("Preserve the published profile graph".into()),
            selected_tool_ids: fixture.selected_tool_ids.clone(),
            context_step_ids: fixture.context_step_ids.clone(),
            ..AgentBuilderCardDraftInput::default()
        },
    )
    .unwrap();
    (app, repository)
}

fn exact(
    repository: &Arc<dyn UnifiedRuntimeStateRepository>,
    profile_id: &str,
    revision: u64,
) -> local_ios_agent_runtime::user_customization::AgentProfile {
    repository
        .agent_profile_exact(
            &AgentProfileId::new(profile_id),
            AgentProfileVersion::new(revision),
        )
        .unwrap()
        .unwrap()
}
