use std::path::Path;
use std::sync::Arc;

use local_ios_agent_runtime::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::llm_contracts::{
    AgentLLMRequirements, BeginLegacyProfileMigration, LegacyProfileMigrationService,
    LLMToolCallingMode,
};
use local_ios_agent_runtime::storage::{
    SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use local_ios_agent_runtime::user_customization::{
    AgentProfileId, AgentProfileVersion, AgentSlotKind,
};
use rusqlite::params;
use serde_json::json;

#[test]
fn direct_old_store_upgrade_preserves_the_complete_profile_graph() {
    let directory = tempfile::tempdir().unwrap();
    let repository = seed_direct_upgrade_store(directory.path());
    let migration = LegacyProfileMigrationService::new(repository.clone());

    let actions = migration.actions().unwrap();
    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "direct-upgrade",
            "fixture.direct.upgrade",
            1,
        ))
        .unwrap();
    let successor = action.successor().unwrap();
    let profile = repository
        .agent_profile_exact(
            &AgentProfileId::new(successor.profile_id()),
            AgentProfileVersion::new(successor.profile_revision()),
        )
        .unwrap()
        .unwrap();

    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].display_name(), "Imported Agent");
    assert_eq!(actions[0].redacted_model_hint(), Some("gpt-4.1-mini"));
    assert_eq!(profile.bindings_for_kind(AgentSlotKind::Persona).len(), 1);
    assert_eq!(
        profile.bindings_for_kind(AgentSlotKind::Instruction).len(),
        1
    );
    assert_eq!(profile.bindings_for_kind(AgentSlotKind::Toolset).len(), 1);
    assert!(profile.llm_slot().is_some());
    assert_eq!(migration.records().unwrap().len(), 1);
}

#[test]
fn final_binary_keeps_translation_but_has_no_v1_execution_entrypoint() {
    let bridge = include_str!("../../src/ffi_bridge.rs");
    let translator = include_str!("../../src/migration/legacy_agent_profile_translator.rs");

    assert!(translator.contains("translate_record"));
    for forbidden in [
        "profile_execution_route_json",
        "start_run_json",
        "send_message_streaming",
    ] {
        assert!(!bridge.contains(forbidden), "legacy entrypoint remains: {forbidden}");
    }
}

fn seed_direct_upgrade_store(root: &Path) -> Arc<SqliteRuntimeStateStore> {
    let path = root.join("agent.sqlite");
    let store = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    let app = AgentOSApplicationService::from_runtime_state(
        AgentOSApplicationServiceConfig::new(),
        store.clone(),
    )
    .unwrap();
    let profile = app
        .build_agent_v2(
            "seed-direct-upgrade",
            Some("fixture.direct.upgrade"),
            "template.assistant.default",
            AgentBuilderCardDraftInput {
                display_name: Some("Imported Agent".into()),
                persona: Some("Migration fixture".into()),
                system_prompt: Some("Preserve the published profile graph".into()),
                selected_tool_ids: vec![
                    "contacts.read".into(),
                    "calendar.events.create".into(),
                ],
                context_step_ids: vec!["memory.retrieve".into(), "attachments.index".into()],
                ..AgentBuilderCardDraftInput::default()
            },
            AgentLLMRequirements::new(
                "slot.model.primary",
                16_384,
                true,
                LLMToolCallingMode::Allowed,
            ),
        )
        .unwrap();
    let mut source = serde_json::to_value(profile).unwrap();
    source.as_object_mut().unwrap().remove("llm_slot");
    source["llm_binding"] = json!({
        "schema": "legacy_v1",
        "binding": {
            "slot_id": "slot.model.primary",
            "selection": {
                "provider_id": "openai",
                "model_id": "gpt-4.1-mini"
            }
        }
    });
    drop(app);
    drop(store);

    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute(
            "update agent_profile_revisions
             set binding_schema = 'legacy_v1', host_binding_state = 'not_required',
                 revision_json = ?1
             where profile_id = 'fixture.direct.upgrade' and profile_revision = '1'",
            params![source.to_string()],
        )
        .unwrap();
    drop(connection);
    Arc::new(SqliteRuntimeStateStore::open(path).unwrap())
}
