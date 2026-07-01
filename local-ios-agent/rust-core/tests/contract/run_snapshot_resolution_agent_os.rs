use local_ios_agent_runtime::run_snapshot::{RunSnapshotService, StartRunRequest};

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
    service
        .repository()
        .mutate_profile_version_for_test("profile_1");

    let error = service.resolve_preview_and_persist(preview).unwrap_err();

    assert_eq!(error.code(), "snapshot.profile_version_conflict");
}

#[test]
fn snapshot_service_rejects_component_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    service
        .repository()
        .mutate_component_entity_version_for_test("persona_v1");

    let error = service.resolve_preview_and_persist(preview).unwrap_err();

    assert_eq!(error.code(), "snapshot.component_version_conflict");
}

#[test]
fn snapshot_service_rejects_model_changed_between_preview_and_persist() {
    let service = RunSnapshotService::fixture();
    let preview = service
        .preview(StartRunRequest::new("profile_1", "hello"))
        .unwrap();
    service
        .repository()
        .mutate_model_catalog_version_for_test("model_binding.primary");

    let error = service.resolve_preview_and_persist(preview).unwrap_err();

    assert_eq!(error.code(), "snapshot.model_version_conflict");
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
