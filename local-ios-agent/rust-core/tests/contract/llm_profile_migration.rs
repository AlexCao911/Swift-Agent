use std::sync::Arc;

use local_ios_agent_runtime::app_service::{
    AgentBuilderCardDraftInput, AgentOSApplicationService, AgentOSApplicationServiceConfig,
};
use local_ios_agent_runtime::canonical_digest::CanonicalDigestV1;
use local_ios_agent_runtime::llm_contracts::{
    AgentHostBindingService, BeginLegacyProfileMigration, HostBindingActivationConfirmation,
    HostBindingCommit, HostBindingStagingReceipt, HostBindingSubjectCatalog, HostBindingTuple,
    LegacyProfileMigrationService, LegacyProfileMigrationState, ProfilePublishPreparation,
};
use local_ios_agent_runtime::migration::LegacyAgentProfileTranslator;
use local_ios_agent_runtime::storage::{
    InMemoryRuntimeStateStore, SqliteRuntimeStateStore, UnifiedRuntimeStateRepository,
};
use local_ios_agent_runtime::user_customization::{
    AgentProfileHostBindingState, AgentProfileId, AgentProfileVersion, AgentSlotKind,
};

#[test]
fn source_digest_binds_the_complete_immutable_legacy_record() {
    let app = legacy_app(Arc::new(InMemoryRuntimeStateStore::new()));
    let source = exact(&app.runtime_state(), "legacy-profile", 1);
    let translated = LegacyAgentProfileTranslator::translate_known_profile(&source).unwrap();
    let digest = LegacyAgentProfileTranslator::source_digest(&source).unwrap();
    let changed = serde_json::from_value({
        let mut value = serde_json::to_value(&source).unwrap();
        value["name"] = serde_json::json!("Changed");
        value
    })
    .unwrap();

    assert!(CanonicalDigestV1::registered_domains().contains("legacy-profile-source:v1"));
    assert_ne!(
        digest,
        LegacyAgentProfileTranslator::source_digest(&changed).unwrap()
    );
    assert_eq!(translated.source_profile_id(), source.id());
    assert_eq!(translated.source_revision(), source.version());
    assert_eq!(translated.component_bindings(), source.bindings());
    assert!(translated.has_component_kind(AgentSlotKind::Toolset));
    assert!(translated.llm_slot().model_id_hint().is_some());
    assert!(translated.successor().model_binding().is_none());
    assert!(translated.successor().local_bindings().is_empty());
}

#[test]
fn legacy_inventory_persists_an_archivable_record_before_migration_begins() {
    let repository = Arc::new(InMemoryRuntimeStateStore::new());
    let _app = legacy_app(repository.clone());
    let migration = LegacyProfileMigrationService::new(repository);

    let records = migration.records().unwrap();

    assert_eq!(records.len(), 1);
    assert!(matches!(
        records[0].state(),
        LegacyProfileMigrationState::Pending { attempt: None }
    ));
    let archived = migration.archive(records[0].source_digest()).unwrap();
    assert!(matches!(
        archived.state(),
        LegacyProfileMigrationState::Archived
    ));
}

#[test]
fn startup_lists_minimal_actions_without_creating_a_successor() {
    let repository = Arc::new(InMemoryRuntimeStateStore::new());
    let _app = legacy_app(repository.clone());
    let migration = LegacyProfileMigrationService::new(repository.clone());

    let actions = migration.actions().unwrap();

    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].migration_subject(), "legacy-profile:1");
    assert_eq!(actions[0].display_name(), "Legacy Agent");
    assert_eq!(actions[0].redacted_model_hint(), Some("gpt-4.1-mini"));
    assert!(actions[0].successor().is_none());
    assert_eq!(
        repository
            .agent_profile_latest(&AgentProfileId::new("legacy-profile"))
            .unwrap()
            .unwrap()
            .version(),
        AgentProfileVersion::new(1)
    );
}

#[test]
fn migration_completion_activates_exact_successor_and_persists_one_record() {
    let repository = Arc::new(InMemoryRuntimeStateStore::new());
    let _app = legacy_app(repository.clone());
    let state = repository.agent_os_state();
    let migration = LegacyProfileMigrationService::new(repository.clone());
    let binding =
        AgentHostBindingService::new(state, HostBindingSubjectCatalog::new(repository.clone()));

    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "attempt-1",
            "legacy-profile",
            1,
        ))
        .unwrap();
    let successor = action.successor().expect("attempt has hidden successor");
    assert_eq!(successor.profile_revision(), 2);
    assert_eq!(
        exact(&repository, "legacy-profile", 1).host_binding_state(),
        AgentProfileHostBindingState::NotRequired
    );
    assert_eq!(
        exact(&repository, "legacy-profile", 2).host_binding_state(),
        AgentProfileHostBindingState::PendingHostBinding
    );
    assert_eq!(
        repository
            .latest_agent_profiles()
            .unwrap()
            .into_iter()
            .find(|profile| profile.id().as_str() == "legacy-profile")
            .unwrap()
            .version(),
        AgentProfileVersion::new(1)
    );

    let operation = binding
        .prepare_profile_publish(ProfilePublishPreparation::new(
            successor.host_binding_operation_id(),
            successor.profile_id(),
            successor.profile_revision(),
            successor.llm_slot_id(),
            successor.requirements_hash(),
        ))
        .unwrap();
    let tuple = HostBindingTuple::new("binding-migrated", 4, "binding-hash-migrated");
    let receipt = HostBindingStagingReceipt::new(
        operation.token_digest(),
        operation.llm_slot_id(),
        operation.requirements_hash(),
        tuple.clone(),
        "migration-staging-receipt",
    );
    let link = binding
        .commit_profile_publish(HostBindingCommit::new(
            operation.token(),
            tuple.clone(),
            receipt,
        ))
        .unwrap();
    assert_eq!(
        repository
            .latest_agent_profiles()
            .unwrap()
            .into_iter()
            .find(|profile| profile.id().as_str() == "legacy-profile")
            .unwrap()
            .version(),
        AgentProfileVersion::new(1)
    );

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
    assert_eq!(
        exact(&repository, "legacy-profile", 2).host_binding_state(),
        AgentProfileHostBindingState::Active
    );
    assert_eq!(migration.records().unwrap().len(), 1);
    assert_eq!(
        repository
            .latest_agent_profiles()
            .unwrap()
            .into_iter()
            .find(|profile| profile.id().as_str() == "legacy-profile")
            .unwrap()
            .version(),
        AgentProfileVersion::new(2)
    );
}

#[test]
fn pending_attempt_reopens_without_rewriting_the_v1_source() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("agent.sqlite");
    let first = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    let app = legacy_app(first.clone());
    let source_before = exact(&first, "legacy-profile", 1);
    let migration = LegacyProfileMigrationService::new(first.clone());
    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "attempt-reopen",
            "legacy-profile",
            1,
        ))
        .unwrap();
    let digest = action.source_digest().to_string();
    drop(migration);
    drop(app);
    drop(first);

    let reopened = Arc::new(SqliteRuntimeStateStore::open(&path).unwrap());
    let migration = LegacyProfileMigrationService::new(reopened.clone());
    let record = migration.record(&digest).unwrap().unwrap();

    assert!(matches!(
        record.state(),
        LegacyProfileMigrationState::Pending { attempt: Some(_) }
    ));
    assert_eq!(exact(&reopened, "legacy-profile", 1), source_before);
}

#[test]
fn abandoning_an_incomplete_attempt_tombstones_only_the_hidden_successor() {
    let repository = Arc::new(InMemoryRuntimeStateStore::new());
    let _app = legacy_app(repository.clone());
    let migration = LegacyProfileMigrationService::new(repository.clone());
    let action = migration
        .begin(BeginLegacyProfileMigration::new(
            "attempt-abandon",
            "legacy-profile",
            1,
        ))
        .unwrap();
    let pending = migration
        .abandon(action.source_digest(), "attempt-abandon")
        .unwrap();

    assert!(matches!(
        pending.state(),
        LegacyProfileMigrationState::Pending { attempt: None }
    ));
    assert_eq!(
        exact(&repository, "legacy-profile", 1).host_binding_state(),
        AgentProfileHostBindingState::NotRequired
    );
    assert_eq!(
        exact(&repository, "legacy-profile", 2).host_binding_state(),
        AgentProfileHostBindingState::Tombstoned
    );

    let retried = migration
        .begin(BeginLegacyProfileMigration::new(
            "attempt-after-abandon",
            "legacy-profile",
            1,
        ))
        .unwrap();
    assert_eq!(retried.successor().unwrap().profile_revision(), 3);
}

fn legacy_app(repository: Arc<dyn UnifiedRuntimeStateRepository>) -> AgentOSApplicationService {
    let app = AgentOSApplicationService::from_runtime_state(
        AgentOSApplicationServiceConfig::new(),
        repository,
    )
    .unwrap();
    app.build_agent_from_template(
        Some("legacy-profile"),
        "template.assistant.default",
        AgentBuilderCardDraftInput {
            display_name: Some("Legacy Agent".into()),
            persona: Some("Careful".into()),
            selected_tool_ids: vec!["contacts.read".into()],
            ..AgentBuilderCardDraftInput::default()
        },
    )
    .unwrap();
    app
}

fn exact<R: UnifiedRuntimeStateRepository + ?Sized>(
    repository: &Arc<R>,
    id: &str,
    revision: u64,
) -> local_ios_agent_runtime::user_customization::AgentProfile {
    repository
        .agent_profile_exact(&AgentProfileId::new(id), AgentProfileVersion::new(revision))
        .unwrap()
        .unwrap()
}
