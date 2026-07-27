use std::path::Path;
use std::sync::Arc;

use local_ios_agent_runtime::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::llm_contracts::{
    AgentHostBindingService, AgentLLMRequirements, BeginLegacyProfileMigration,
    HostBindingActivationConfirmation, HostBindingCommit, HostBindingStagingReceipt,
    HostBindingSubjectCatalog, HostBindingTuple, LegacyProfileMigrationService,
    LegacyProfileMigrationState, LLMToolCallingMode, ProfilePublishPreparation,
};
use local_ios_agent_runtime::migration::LegacyAgentProfileTranslator;
use local_ios_agent_runtime::storage::{
    SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use local_ios_agent_runtime::user_customization::{
    AgentProfileHostBindingState, AgentProfileId, AgentProfileVersion, AgentSlotKind,
};
use rusqlite::params;

#[test]
fn source_digest_binds_the_complete_immutable_legacy_record() {
    let source = canonical_legacy_source_json();
    let translated = LegacyAgentProfileTranslator::translate_record(&source).unwrap();
    let digest = LegacyAgentProfileTranslator::source_digest(&source).unwrap();
    let changed = {
        let mut value: serde_json::Value = serde_json::from_str(&source).unwrap();
        value["name"] = serde_json::json!("Changed");
        value.to_string()
    };

    assert!(CanonicalDigestV1::registered_domains().contains("legacy-profile-source:v1"));
    assert_ne!(
        digest,
        LegacyAgentProfileTranslator::source_digest(&changed).unwrap()
    );
    assert_eq!(translated.source_profile_id().as_str(), "legacy-profile");
    assert_eq!(translated.source_revision(), AgentProfileVersion::new(1));
    assert!(translated.has_component_kind(AgentSlotKind::Toolset));
    assert_eq!(translated.redacted_model_hint(), Some("gpt-4.1"));
}

#[test]
fn startup_inventory_persists_one_minimal_archivable_action() {
    let directory = tempfile::tempdir().unwrap();
    let repository = seed_legacy_store(directory.path());
    let migration = LegacyProfileMigrationService::new(repository);

    let actions = migration.actions().unwrap();

    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].migration_subject(), "legacy-profile:1");
    assert_eq!(actions[0].display_name(), "Legacy Agent");
    assert_eq!(actions[0].redacted_model_hint(), Some("gpt-4.1-mini"));
    assert!(actions[0].successor().is_none());
    let archived = migration.archive(actions[0].source_digest()).unwrap();
    assert!(matches!(
        archived.state(),
        LegacyProfileMigrationState::Archived
    ));
}

#[test]
fn begin_is_idempotent_and_creates_a_hidden_v2_successor() {
    let directory = tempfile::tempdir().unwrap();
    let repository = seed_legacy_store(directory.path());
    let migration = LegacyProfileMigrationService::new(repository.clone());
    let request = || BeginLegacyProfileMigration::new("attempt-1", "legacy-profile", 1);

    let first = migration.begin(request()).unwrap();
    let replay = migration.begin(request()).unwrap();
    let successor = first.successor().unwrap();

    assert_eq!(replay, first);
    assert_eq!(successor.profile_revision(), 2);
    let profile = repository
        .agent_profile_exact(
            &AgentProfileId::new(successor.profile_id()),
            AgentProfileVersion::new(successor.profile_revision()),
        )
        .unwrap()
        .unwrap();
    assert!(profile.llm_slot().is_some());
    assert_eq!(
        profile.host_binding_state(),
        AgentProfileHostBindingState::PendingHostBinding
    );
    assert_eq!(migration.records().unwrap().len(), 1);
}

#[test]
fn pending_attempt_reopens_without_rewriting_the_source() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().to_path_buf();
    let repository = seed_legacy_store(&path);
    let migration = LegacyProfileMigrationService::new(repository);
    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "attempt-reopen",
            "legacy-profile",
            1,
        ))
        .unwrap();
    let digest = action.source_digest().to_string();
    drop(migration);

    let reopened = Arc::new(SqliteRuntimeStateStore::open(path.join("agent.sqlite")).unwrap());
    let record = LegacyProfileMigrationService::new(reopened)
        .record(&digest)
        .unwrap()
        .unwrap();

    assert!(matches!(
        record.state(),
        LegacyProfileMigrationState::Pending { attempt: Some(_) }
    ));
}

#[test]
fn completion_activates_the_exact_host_bound_successor() {
    let directory = tempfile::tempdir().unwrap();
    let repository = seed_legacy_store(directory.path());
    let migration = LegacyProfileMigrationService::new(repository.clone());
    let binding = AgentHostBindingService::new(
        repository.agent_os_state(),
        HostBindingSubjectCatalog::new(repository.clone()),
    );
    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "attempt-complete",
            "legacy-profile",
            1,
        ))
        .unwrap();
    let successor = action.successor().unwrap();
    let operation = binding
        .prepare_profile_publish(ProfilePublishPreparation::new(
            successor.host_binding_operation_id(),
            successor.profile_id(),
            successor.profile_revision(),
            successor.llm_slot_id(),
            successor.requirements_hash(),
        ))
        .unwrap();
    let tuple = HostBindingTuple::new("binding-migrated", 1, "binding-hash-migrated");
    let link = binding
        .commit_profile_publish(HostBindingCommit::new(
            operation.token(),
            tuple.clone(),
            HostBindingStagingReceipt::new(
                operation.token_digest(),
                operation.llm_slot_id(),
                operation.requirements_hash(),
                tuple.clone(),
                "migration-staging-receipt",
            ),
        ))
        .unwrap();

    let completed = migration
        .complete(HostBindingActivationConfirmation::new(
            successor.profile_id(),
            successor.profile_revision(),
            successor.llm_slot_id(),
            successor.requirements_hash(),
            tuple,
            link.staging_receipt_digest(),
        ))
        .unwrap();

    assert!(matches!(
        completed.state(),
        LegacyProfileMigrationState::Migrated { .. }
    ));
    let profile = repository
        .agent_profile_exact(
            &AgentProfileId::new(successor.profile_id()),
            AgentProfileVersion::new(successor.profile_revision()),
        )
        .unwrap()
        .unwrap();
    assert_eq!(
        profile.host_binding_state(),
        AgentProfileHostBindingState::Active
    );
}

fn seed_legacy_store(root: &Path) -> Arc<SqliteRuntimeStateStore> {
    let path = root.join("agent.sqlite");
    let store = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    let app = AgentOSApplicationService::from_runtime_state(
        AgentOSApplicationServiceConfig::new(),
        store.clone(),
    )
    .unwrap();
    let profile = app
        .build_agent_v2(
            "seed-legacy-profile",
            Some("legacy-profile"),
            "template.assistant.default",
            AgentBuilderCardDraftInput {
                display_name: Some("Legacy Agent".into()),
                persona: Some("Careful".into()),
                selected_tool_ids: vec!["contacts.read".into()],
                ..AgentBuilderCardDraftInput::default()
            },
            AgentLLMRequirements::new(
                "slot.model.primary",
                4_096,
                true,
                LLMToolCallingMode::Allowed,
            ),
        )
        .unwrap();
    let mut source = serde_json::to_value(&profile).unwrap();
    source.as_object_mut().unwrap().remove("llm_slot");
    source["llm_binding"] = serde_json::json!({
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
             where profile_id = 'legacy-profile' and profile_revision = '1'",
            params![source.to_string()],
        )
        .unwrap();
    drop(connection);
    Arc::new(SqliteRuntimeStateStore::open(path).unwrap())
}

fn canonical_legacy_source_json() -> String {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/canonical-digest-v1/fixtures/legacy-profile-source-v1.json"
    ))
    .unwrap();
    fixture["document"]["source_record"].to_string()
}
