use local_ios_agent_runtime::protocol::{
    ComponentDefinition, DefinitionCompatibility, DefinitionId, ModuleId, ProviderDefinition,
    RegistryError, SchemaVersion, TypedRegistry,
};

#[derive(Clone, Debug)]
struct TestDefinition {
    id: DefinitionId,
    display_name: String,
    compatibility: DefinitionCompatibility,
}

impl TestDefinition {
    fn new(id: impl Into<String>) -> Self {
        let id = id.into();
        Self {
            display_name: id.clone(),
            id: DefinitionId::new(id),
            compatibility: DefinitionCompatibility::compatible(),
        }
    }

    fn incompatible(id: impl Into<String>, reason: impl Into<String>) -> Self {
        let mut definition = Self::new(id);
        definition.compatibility = DefinitionCompatibility::incompatible(reason);
        definition
    }
}

impl ComponentDefinition for TestDefinition {
    fn id(&self) -> DefinitionId {
        self.id.clone()
    }

    fn schema_version(&self) -> SchemaVersion {
        SchemaVersion::new(1, 0)
    }

    fn display_name(&self) -> &str {
        &self.display_name
    }

    fn compatibility(&self) -> DefinitionCompatibility {
        self.compatibility.clone()
    }
}

#[test]
fn protocol_ids_are_stable_strings() {
    assert_eq!(ModuleId::new("builtin.openai").as_str(), "builtin.openai");
    assert_eq!(
        DefinitionId::new("provider.openai").as_str(),
        "provider.openai"
    );
    assert_eq!(SchemaVersion::new(1, 0).to_string(), "1.0");
}

#[test]
fn registry_rejects_duplicate_definition_id() {
    let mut registry = TypedRegistry::new();
    registry
        .insert(TestDefinition::new("provider.openai"))
        .unwrap();

    let error = registry
        .insert(TestDefinition::new("provider.openai"))
        .unwrap_err();

    assert!(matches!(error, RegistryError::DuplicateDefinitionId(_)));
}

#[test]
fn frozen_registry_rejects_late_insert() {
    let mut registry = TypedRegistry::new();
    registry
        .insert(TestDefinition::new("provider.openai"))
        .unwrap();
    registry.freeze();

    let error = registry
        .insert(TestDefinition::new("provider.local"))
        .unwrap_err();

    assert!(matches!(error, RegistryError::Frozen));
}

#[test]
fn registry_rejects_incompatible_definition() {
    let mut registry = TypedRegistry::new();

    let error = registry
        .insert(TestDefinition::incompatible(
            "provider.future",
            "schema too new",
        ))
        .unwrap_err();

    assert!(matches!(
        error,
        RegistryError::IncompatibleDefinition { .. }
    ));
}

#[test]
fn production_definition_can_carry_metadata_and_compatibility() {
    let definition = ProviderDefinition::new("provider.future")
        .with_display_name("Future Provider")
        .with_schema_version(SchemaVersion::new(2, 1))
        .with_compatibility(DefinitionCompatibility::incompatible("requires host v2"));

    assert_eq!(definition.display_name(), "Future Provider");
    assert_eq!(definition.schema_version(), SchemaVersion::new(2, 1));
    assert!(!definition.compatibility().is_compatible());
    assert_eq!(
        definition.compatibility().reason(),
        Some("requires host v2")
    );
}

#[test]
fn registry_rejects_incompatible_production_definition() {
    let mut registry = TypedRegistry::new();

    let error = registry
        .insert(
            ProviderDefinition::new("provider.future")
                .with_compatibility(DefinitionCompatibility::incompatible("schema too new")),
        )
        .unwrap_err();

    assert!(matches!(
        error,
        RegistryError::IncompatibleDefinition { .. }
    ));
}
