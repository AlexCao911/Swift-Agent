use local_ios_agent_runtime::protocol::{
    ArchiveId, BindingId, ComponentArchive, ComponentBinding, ComponentInstance, DefinitionId,
    InstanceId, SchemaVersion, SlotKey, SnapshotArchiveKind, SnapshotId, SnapshotRecord,
    SnapshotSource,
};

#[test]
fn component_instance_pins_definition_and_schema_version() {
    let instance = ComponentInstance::new(
        InstanceId::new("provider.openai.default"),
        DefinitionId::new("provider.openai"),
        SchemaVersion::new(1, 0),
    );

    assert_eq!(instance.id().as_str(), "provider.openai.default");
    assert_eq!(instance.definition_id().as_str(), "provider.openai");
    assert_eq!(instance.schema_version(), SchemaVersion::new(1, 0));
}

#[test]
fn component_binding_links_slot_to_instance_without_runtime_state() {
    let binding = ComponentBinding::new(
        BindingId::new("binding.model.primary"),
        SlotKey::new("model.primary"),
        InstanceId::new("provider.openai.default"),
    );

    assert_eq!(binding.id().as_str(), "binding.model.primary");
    assert_eq!(binding.slot_key().as_str(), "model.primary");
    assert_eq!(binding.instance_id().as_str(), "provider.openai.default");
}

#[test]
fn snapshot_records_source_and_binding_ids_without_runtime_execution_state() {
    let snapshot = SnapshotRecord::new(
        SnapshotId::new("snapshot.run_1"),
        SnapshotSource::agent_profile("profile.research"),
        SchemaVersion::new(1, 0),
    )
    .with_binding(BindingId::new("binding.model.primary"))
    .with_binding(BindingId::new("binding.tool.search"));

    assert_eq!(snapshot.id().as_str(), "snapshot.run_1");
    assert_eq!(snapshot.source().as_str(), "profile.research");
    assert_eq!(snapshot.binding_ids().len(), 2);
    assert_eq!(snapshot.schema_version(), SchemaVersion::new(1, 0));
}

#[test]
fn archive_links_to_snapshot_and_declares_archive_kind() {
    let archive = ComponentArchive::new(
        ArchiveId::new("archive.prompt.run_1"),
        SnapshotId::new("snapshot.run_1"),
        SnapshotArchiveKind::Prompt,
        SchemaVersion::new(1, 0),
    );

    assert_eq!(archive.id().as_str(), "archive.prompt.run_1");
    assert_eq!(archive.snapshot_id().as_str(), "snapshot.run_1");
    assert_eq!(archive.kind(), SnapshotArchiveKind::Prompt);
    assert_eq!(archive.schema_version(), SchemaVersion::new(1, 0));
}
