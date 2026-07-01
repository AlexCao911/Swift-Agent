use std::sync::Arc;

use local_ios_agent_runtime::model::{
    InMemoryModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use local_ios_agent_runtime::run_snapshot::{RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::security::{
    CredentialPurpose, InMemoryCredentialResolver, PermissionState, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::storage::{
    InMemoryTransactionRunner, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
};
use local_ios_agent_runtime::user_customization::{
    AgentProfileDraft, AgentProfileId, AgentProfileLocalBindings, AgentProfileModelBinding,
    AgentProfilePublisher, AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService,
    ComponentContent, InMemoryAgentProfileRepository,
};

struct ModelSelectionStage<'a> {
    catalog: &'a InMemoryModelBindingCatalog,
    selection: ModelSelection,
}

#[test]
fn start_run_request_contains_only_profile_id_and_user_intent() {
    let request = StartRunRequest::new("profile_1", "user asked a question");

    assert_eq!(request.agent_profile_id().as_str(), "profile_1");
    assert_eq!(request.user_intent().as_str(), "user asked a question");
}

#[test]
fn snapshot_preview_pins_component_versions_and_model_binding() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    let snapshot = preview.snapshot();

    assert_eq!(snapshot.agent_profile_id().as_str(), "profile_1");
    assert_eq!(snapshot.profile_version().as_u64(), 1);
    assert_eq!(
        snapshot.component_versions()[0].version_id().as_str(),
        "persona_v1"
    );
    assert_eq!(
        snapshot.component_versions()[0].entity_version().as_u64(),
        1
    );
    assert_eq!(snapshot.model_binding().model_id().as_str(), "gpt-4.1-mini");
    assert_eq!(snapshot.model_binding().catalog_version().as_u64(), 7);
    assert_eq!(
        snapshot
            .trusted_host_state()
            .credential_availability()
            .credential_ref_for("account.openai.default"),
        Some("credential.openai.default")
    );
    assert_eq!(
        snapshot.trusted_host_state().permission_state(),
        &PermissionState::Granted
    );
    assert!(snapshot.tool_bindings().is_empty());
    assert!(snapshot.memory_binding().is_none());
    assert!(snapshot.voice_binding().is_none());
    assert!(snapshot.readiness_report().is_ready());
}

#[test]
fn snapshot_service_consumes_published_profile_from_real_repositories() {
    let template = AgentTemplate::assistant_default();
    let component_catalog = ComponentCatalogService::default();
    let component_id = component_catalog.create_draft(ComponentContent::persona("Real persona"));
    let persona_version = component_catalog.publish(component_id).unwrap();
    let model_catalog = InMemoryModelBindingCatalog::default();
    let model_selection = primary_model_selection(ModelCatalogVersion::new(3));
    stage_model_selection(&model_catalog, model_selection.clone());

    let profile_repository = InMemoryAgentProfileRepository::default();
    let publisher = AgentProfilePublisher::new(
        Box::new(InMemoryTransactionRunner::default()),
        profile_repository.clone(),
    );
    let draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.real"),
        template.id().clone(),
        "Real profile",
    )
    .bind(ComponentBinding::persona(
        template
            .slot_id_for_kind(AgentSlotKind::Persona)
            .unwrap()
            .clone(),
        persona_version,
    ))
    .with_model_binding(AgentProfileModelBinding::new(
        template
            .slot_id_for_kind(AgentSlotKind::Model)
            .unwrap()
            .clone(),
        model_selection,
    ))
    .with_local_bindings(
        AgentProfileLocalBindings::default()
            .with_credential_ref("account.openai.default", "credential.openai.default"),
    );
    publisher
        .publish(
            draft,
            &template,
            &component_catalog,
            &local_ios_agent_runtime::model::ModelBindingCatalog::default()
                .with_selection(primary_model_selection(ModelCatalogVersion::new(3))),
        )
        .unwrap();

    let service = RunSnapshotService::from_real_repositories(
        profile_repository,
        component_catalog,
        model_catalog,
        Arc::new(
            StaticSecurityPermissionService::default()
                .with_permission("run.start", PermissionState::Granted),
        ),
        Arc::new(InMemoryCredentialResolver::default().with_secret_for(
            "credential.openai.default",
            "secret",
            [CredentialPurpose::RemoteProvider],
        )),
        Box::new(InMemoryTransactionRunner::default()),
    );

    let snapshot = service
        .resolve_and_persist(StartRunRequest::new("profile.real", "hello"))
        .unwrap();

    assert_eq!(snapshot.agent_profile_id().as_str(), "profile.real");
    assert_eq!(
        snapshot.component_versions()[0].version_id().as_str(),
        "persona_v1"
    );
    assert_eq!(snapshot.model_binding().model_id().as_str(), "gpt-4.1-mini");
}

#[test]
fn snapshot_service_persists_snapshot_before_runtime() {
    let service = RunSnapshotService::fixture();
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new("profile_1", "hello"))
        .unwrap();

    assert!(service.repository().contains(snapshot.snapshot_id()));
    assert!(!service.runtime_was_started());
}

#[test]
fn snapshot_service_rejects_profile_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    let changed_service = RunSnapshotService::fixture_with_profile_version(2);

    let error = changed_service
        .resolve_preview_and_persist(preview)
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.profile_version_conflict");
}

#[test]
fn snapshot_service_rejects_component_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    let changed_service = RunSnapshotService::fixture_with_component_entity_version(2);

    let error = changed_service
        .resolve_preview_and_persist(preview)
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.component_version_conflict");
}

#[test]
fn snapshot_service_rejects_model_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    let changed_service = RunSnapshotService::fixture_with_model_catalog_version(8);

    let error = changed_service
        .resolve_preview_and_persist(preview)
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.model_version_conflict");
}

#[test]
fn snapshot_service_rejects_model_content_changed_at_same_catalog_version() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    let changed_service =
        RunSnapshotService::fixture_with_model_id_at_same_catalog_version("gpt-4o");

    let error = changed_service
        .resolve_preview_and_persist(preview)
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.model_version_conflict");
}

#[test]
fn snapshot_service_allocates_snapshot_ids_at_persist_time() {
    let service = RunSnapshotService::fixture();
    let first_preview = service
        .preview(StartRunRequest::new("profile_1", "first"))
        .unwrap();
    let second_preview = service
        .preview(StartRunRequest::new("profile_1", "second"))
        .unwrap();

    let first = service.resolve_preview_and_persist(first_preview).unwrap();
    let second = service.resolve_preview_and_persist(second_preview).unwrap();

    assert_ne!(first.snapshot_id(), second.snapshot_id());
    assert!(service.repository().contains(first.snapshot_id()));
    assert!(service.repository().contains(second.snapshot_id()));
}

#[test]
fn snapshot_service_captures_denied_permission_from_security_service() {
    let service = RunSnapshotService::fixture_with_permission_state(PermissionState::Denied);

    let snapshot = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();

    assert_eq!(
        snapshot.snapshot().trusted_host_state().permission_state(),
        &PermissionState::Denied
    );
    assert!(!snapshot.snapshot().readiness_report().is_ready());
    assert!(snapshot
        .snapshot()
        .readiness_report()
        .has_issue("snapshot.permission_not_granted"));
}

#[test]
fn snapshot_service_rejects_unresolvable_model_credential() {
    let service = RunSnapshotService::fixture_without_credentials();

    let error = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.credential_unavailable");
}

#[test]
fn snapshot_service_pins_versions_inside_one_transaction() {
    let service = RunSnapshotService::fixture();
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new("profile_1", "hello"))
        .unwrap();

    assert_eq!(
        snapshot.profile_version().as_u64(),
        service
            .repository()
            .stored_snapshot_profile_version(snapshot.snapshot_id())
    );
    assert_eq!(
        snapshot.component_versions()[0].entity_version().as_u64(),
        1
    );
    assert_eq!(snapshot.model_binding().catalog_version().as_u64(), 7);
}

impl TransactionOperation for ModelSelectionStage<'_> {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        self.catalog.stage(tx, self.selection.clone())
    }
}

fn stage_model_selection(catalog: &InMemoryModelBindingCatalog, selection: ModelSelection) {
    let mut operation = ModelSelectionStage { catalog, selection };
    InMemoryTransactionRunner::default()
        .run(
            TransactionName::new("test.model_binding.stage"),
            &mut operation,
        )
        .unwrap();
}

fn primary_model_selection(catalog_version: ModelCatalogVersion) -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        "gpt-4.1-mini",
        catalog_version,
    )
}
