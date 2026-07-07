use std::sync::Arc;

use local_ios_agent_runtime::conversation::{ConversationFrameId, ConversationRunFrameRef};
use local_ios_agent_runtime::core::{EntryId, SessionId};
use local_ios_agent_runtime::model::{
    InMemoryModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use local_ios_agent_runtime::run_snapshot::{RunSnapshotId, RunSnapshotService, StartRunRequest};
use local_ios_agent_runtime::security::{
    CredentialPurpose, InMemoryCredentialResolver, PermissionState, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::storage::{
    InMemoryTransactionRunner, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
};
use local_ios_agent_runtime::user_customization::{
    AgentProfileDraft, AgentProfileId, AgentProfileLocalBindings, AgentProfileModelBinding,
    AgentProfilePublisher, AgentProfileVersion, AgentSlotKind, AgentTemplate, ComponentBinding,
    ComponentCatalogService, ComponentContent, InMemoryAgentProfileRepository,
};

struct ModelSelectionStage<'a> {
    catalog: &'a InMemoryModelBindingCatalog,
    selection: ModelSelection,
}

fn frame_ref_fixture() -> ConversationRunFrameRef {
    ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_1"),
        SessionId("session_1".into()),
        EntryId("branch_head_1".into()),
        EntryId("user_turn_1".into()),
    )
}

#[test]
fn start_run_request_requires_conversation_run_frame_ref() {
    let request = StartRunRequest::new(
        "profile_1",
        AgentProfileVersion::initial(),
        "user asked a question",
        frame_ref_fixture(),
    );

    assert_eq!(request.agent_profile_id().as_str(), "profile_1");
    assert_eq!(request.user_intent().as_str(), "user asked a question");
    assert_eq!(
        request.conversation_run_frame_ref().frame_id().as_str(),
        "frame_1"
    );
}

#[test]
fn start_run_uses_pinned_profile_revision_not_latest() {
    let service = RunSnapshotService::fixture_with_profile_version(2);

    let error = service
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::new(1),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.profile_revision_missing");
}

#[test]
fn resolved_snapshot_pins_conversation_run_frame_ref() {
    let service = RunSnapshotService::fixture();
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap();

    assert_eq!(
        snapshot.conversation_run_frame_ref().frame_id().as_str(),
        "frame_1"
    );
    assert_eq!(
        snapshot.conversation_run_frame_ref().branch_head_id().0,
        "branch_head_1"
    );
}

#[test]
fn snapshot_preview_pins_component_versions_and_model_binding() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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
        .resolve_and_persist(StartRunRequest::new(
            "profile.real",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap();

    assert!(service.repository().contains(snapshot.snapshot_id()));
    assert!(!service.runtime_was_started());
}

#[test]
fn snapshot_service_rejects_profile_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap();
    let changed_service = RunSnapshotService::fixture_with_profile_version(2);

    let error = changed_service
        .resolve_preview_and_persist(preview)
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.profile_revision_missing");
}

#[test]
fn snapshot_service_rejects_component_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "first",
            frame_ref_fixture(),
        ))
        .unwrap();
    let second_preview = service
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "second",
            frame_ref_fixture(),
        ))
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
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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
        .preview(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.credential_unavailable");
}

#[test]
fn snapshot_service_rejects_missing_model_credential_binding() {
    let template = AgentTemplate::assistant_default();
    let component_catalog = ComponentCatalogService::default();
    let persona_version =
        publish_component(&component_catalog, ComponentContent::persona("Persona"));
    let model_selection = primary_model_selection(ModelCatalogVersion::new(3));
    let profile_repository = publish_profile(
        &template,
        &component_catalog,
        persona_version,
        model_selection.clone(),
        AgentProfileLocalBindings::default(),
    );
    let model_catalog = InMemoryModelBindingCatalog::default();
    stage_model_selection(&model_catalog, model_selection);
    let service = service_from_repositories(profile_repository, component_catalog, model_catalog);

    let error = service
        .preview(StartRunRequest::new(
            "profile.real",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.credential_binding_missing");
}

#[test]
fn snapshot_service_rejects_model_catalog_selection_that_differs_from_profile_pin() {
    let template = AgentTemplate::assistant_default();
    let component_catalog = ComponentCatalogService::default();
    let _persona_version =
        publish_component(&component_catalog, ComponentContent::persona("Persona"));
    let pinned_selection = primary_model_selection(ModelCatalogVersion::new(3));
    let profile_repository = publish_profile(
        &template,
        &component_catalog,
        _persona_version,
        pinned_selection,
        AgentProfileLocalBindings::default()
            .with_credential_ref("account.openai.default", "credential.openai.default"),
    );
    let model_catalog = InMemoryModelBindingCatalog::default();
    stage_model_selection(
        &model_catalog,
        model_selection_with_id(ModelCatalogVersion::new(3), "gpt-4o"),
    );
    let service = service_from_repositories(profile_repository, component_catalog, model_catalog);

    let error = service
        .preview(StartRunRequest::new(
            "profile.real",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.model_selection_conflict");
}

#[test]
fn snapshot_service_does_not_persist_permission_denied_snapshot() {
    let service = RunSnapshotService::fixture_with_permission_state(PermissionState::Denied);

    let error = service
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.not_ready");
    assert!(!service.repository().contains(RunSnapshotId::new(1)));
}

#[test]
fn snapshot_service_rejects_component_kind_drift_at_resolution() {
    let template = AgentTemplate::assistant_default();
    let publishing_catalog = ComponentCatalogService::default();
    let _persona_version =
        publish_component(&publishing_catalog, ComponentContent::persona("Persona"));
    let model_selection = primary_model_selection(ModelCatalogVersion::new(3));
    let profile_repository = publish_profile(
        &template,
        &publishing_catalog,
        _persona_version,
        model_selection.clone(),
        AgentProfileLocalBindings::default()
            .with_credential_ref("account.openai.default", "credential.openai.default"),
    );
    let drifted_catalog = ComponentCatalogService::default();
    let _instruction_version = publish_component(
        &drifted_catalog,
        ComponentContent::instruction("Wrong kind"),
    );
    let model_catalog = InMemoryModelBindingCatalog::default();
    stage_model_selection(&model_catalog, model_selection);
    let service = service_from_repositories(profile_repository, drifted_catalog, model_catalog);

    let error = service
        .preview(StartRunRequest::new(
            "profile.real",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
        .unwrap_err();

    assert_eq!(error.code(), "snapshot.component_kind_mismatch");
}

#[test]
fn snapshot_service_pins_versions_inside_one_transaction() {
    let service = RunSnapshotService::fixture();
    let snapshot = service
        .resolve_and_persist(StartRunRequest::new(
            "profile_1",
            AgentProfileVersion::initial(),
            "hello",
            frame_ref_fixture(),
        ))
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

fn service_from_repositories(
    profile_repository: InMemoryAgentProfileRepository,
    component_catalog: ComponentCatalogService,
    model_catalog: InMemoryModelBindingCatalog,
) -> RunSnapshotService {
    RunSnapshotService::from_real_repositories(
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
    )
}

fn publish_profile(
    template: &AgentTemplate,
    component_catalog: &ComponentCatalogService,
    persona_version: local_ios_agent_runtime::user_customization::UserComponentVersionId,
    model_selection: ModelSelection,
    local_bindings: AgentProfileLocalBindings,
) -> InMemoryAgentProfileRepository {
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
        model_selection.clone(),
    ))
    .with_local_bindings(local_bindings);

    publisher
        .publish(
            draft,
            template,
            component_catalog,
            &local_ios_agent_runtime::model::ModelBindingCatalog::default()
                .with_selection(model_selection),
        )
        .unwrap();
    profile_repository
}

fn publish_component(
    component_catalog: &ComponentCatalogService,
    content: ComponentContent,
) -> local_ios_agent_runtime::user_customization::UserComponentVersionId {
    let component_id = component_catalog.create_draft(content);
    component_catalog.publish(component_id).unwrap()
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
    model_selection_with_id(catalog_version, "gpt-4.1-mini")
}

fn model_selection_with_id(
    catalog_version: ModelCatalogVersion,
    model_id: impl Into<String>,
) -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        model_id,
        catalog_version,
    )
}
