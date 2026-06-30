# Protocol Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the protocol foundation for definition, instance, binding, snapshot, plugin module, and typed registries.

**Architecture:** `protocol` is a pure Rust module with no runtime, storage, Swift, or C++ dependency. It defines typed IDs, registry construction, duplicate rejection, freeze semantics, and unknown-safe DTO-facing enums.

**Tech Stack:** Rust 2021, existing `local_ios_agent_runtime` crate, Cargo tests, serde for fixture-ready DTO shapes.

---

## Source Design

Read first:

```text
local-ios-agent/docs/agent-os-design-slices/01-protocol-foundation-design.md
local-ios-agent/docs/agent-os-design-slices/README.md
```

## File Structure

Create:

```text
local-ios-agent/rust-core/src/protocol/mod.rs
local-ios-agent/rust-core/src/protocol/ids.rs
local-ios-agent/rust-core/src/protocol/schema_version.rs
local-ios-agent/rust-core/src/protocol/instance.rs
local-ios-agent/rust-core/src/protocol/binding.rs
local-ios-agent/rust-core/src/protocol/snapshot.rs
local-ios-agent/rust-core/src/protocol/archive.rs
local-ios-agent/rust-core/src/protocol/plugin_module.rs
local-ios-agent/rust-core/src/protocol/typed_registry.rs
local-ios-agent/rust-core/src/protocol/runtime_plugin_registry.rs
local-ios-agent/rust-core/src/protocol/host_capability.rs
local-ios-agent/rust-core/src/protocol/unknown_enum.rs
local-ios-agent/rust-core/tests/protocol_lifecycle.rs
local-ios-agent/rust-core/tests/protocol_registry.rs
local-ios-agent/rust-core/tests/protocol_plugin_module.rs
local-ios-agent/rust-core/tests/protocol_dto_unknown.rs
```

Modify:

```text
local-ios-agent/rust-core/src/lib.rs
```

## Task 1: Add Typed IDs and Schema Version

**Files:**
- Create: `local-ios-agent/rust-core/src/protocol/ids.rs`
- Create: `local-ios-agent/rust-core/src/protocol/schema_version.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/mod.rs`
- Test: `local-ios-agent/rust-core/tests/protocol_registry.rs`

- [ ] **Step 1: Write failing ID test**

```rust
use local_ios_agent_runtime::protocol::{DefinitionId, ModuleId, SchemaVersion};

#[test]
fn protocol_ids_are_stable_strings() {
    assert_eq!(ModuleId::new("builtin.openai").as_str(), "builtin.openai");
    assert_eq!(DefinitionId::new("provider.openai").as_str(), "provider.openai");
    assert_eq!(SchemaVersion::new(1, 0).to_string(), "1.0");
}
```

- [ ] **Step 2: Run failing test**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test protocol_registry protocol_ids_are_stable_strings
```

Expected: unresolved import for `protocol`.

- [ ] **Step 3: Implement IDs**

```rust
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct ModuleId(String);

impl ModuleId {
    pub fn new(value: impl Into<String>) -> Self { Self(value.into()) }
    pub fn as_str(&self) -> &str { &self.0 }
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct DefinitionId(String);

impl DefinitionId {
    pub fn new(value: impl Into<String>) -> Self { Self(value.into()) }
    pub fn as_str(&self) -> &str { &self.0 }
}
```

- [ ] **Step 4: Export module**

Add to `src/lib.rs`:

```rust
pub mod protocol;
```

- [ ] **Step 5: Run passing test**

Run:

```bash
cargo test --test protocol_registry protocol_ids_are_stable_strings
```

Expected: test passes.

## Task 2: Add Object-Safe Plugin Module and Typed Registry

**Files:**
- Create: `local-ios-agent/rust-core/src/protocol/plugin_module.rs`
- Create: `local-ios-agent/rust-core/src/protocol/typed_registry.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/mod.rs`
- Test: `local-ios-agent/rust-core/tests/protocol_registry.rs`

- [ ] **Step 1: Write duplicate/freeze tests**

```rust
use local_ios_agent_runtime::protocol::{
    ComponentDefinition, DefinitionCompatibility, DefinitionId, RegistryError, SchemaVersion,
    TypedRegistry,
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
    fn id(&self) -> DefinitionId { self.id.clone() }
    fn schema_version(&self) -> SchemaVersion { SchemaVersion::new(1, 0) }
    fn display_name(&self) -> &str { &self.display_name }
    fn compatibility(&self) -> DefinitionCompatibility { self.compatibility.clone() }
}

#[test]
fn registry_rejects_duplicate_definition_id() {
    let mut registry = TypedRegistry::new();
    registry.insert(TestDefinition::new("provider.openai")).unwrap();
    let error = registry.insert(TestDefinition::new("provider.openai")).unwrap_err();
    assert!(matches!(error, RegistryError::DuplicateDefinitionId(_)));
}

#[test]
fn frozen_registry_rejects_late_insert() {
    let mut registry = TypedRegistry::new();
    registry.insert(TestDefinition::new("provider.openai")).unwrap();
    registry.freeze();
    let error = registry.insert(TestDefinition::new("provider.local")).unwrap_err();
    assert!(matches!(error, RegistryError::Frozen));
}

#[test]
fn registry_rejects_incompatible_definition() {
    let mut registry = TypedRegistry::new();
    let error = registry
        .insert(TestDefinition::incompatible("provider.future", "schema too new"))
        .unwrap_err();

    assert!(matches!(error, RegistryError::IncompatibleDefinition { .. }));
}
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
cargo test --test protocol_registry registry_
```

Expected: unresolved `TypedRegistry`.

- [ ] **Step 3: Implement registry**

```rust
use std::collections::BTreeMap;

pub trait ComponentDefinition {
    fn id(&self) -> DefinitionId;
    fn schema_version(&self) -> SchemaVersion;
    fn display_name(&self) -> &str;
    fn compatibility(&self) -> DefinitionCompatibility;
}

pub struct TypedRegistry<T: ComponentDefinition> {
    definitions: BTreeMap<DefinitionId, T>,
    frozen: bool,
}

impl<T: ComponentDefinition> TypedRegistry<T> {
    pub fn new() -> Self { Self { definitions: BTreeMap::new(), frozen: false } }
    pub fn insert(&mut self, definition: T) -> Result<(), RegistryError> {
        if self.frozen { return Err(RegistryError::Frozen); }
        if !definition.compatibility().is_compatible() {
            return Err(RegistryError::IncompatibleDefinition { id: definition.id(), reason: definition.compatibility().reason().unwrap_or("").to_string() });
        }
        let id = definition.id();
        if self.definitions.contains_key(&id) {
            return Err(RegistryError::DuplicateDefinitionId(id));
        }
        self.definitions.insert(id, definition);
        Ok(())
    }
    pub fn freeze(&mut self) { self.frozen = true; }
}
```

Do not export test-only definitions from `protocol`; integration tests define their own `TestDefinition` implementations.

- [ ] **Step 4: Run tests**

Run:

```bash
cargo test --test protocol_registry
```

Expected: all protocol registry tests pass.

## Task 2b: Add Instance, Binding, Snapshot, and Archive Shells

**Files:**
- Create: `local-ios-agent/rust-core/src/protocol/instance.rs`
- Create: `local-ios-agent/rust-core/src/protocol/binding.rs`
- Create: `local-ios-agent/rust-core/src/protocol/snapshot.rs`
- Create: `local-ios-agent/rust-core/src/protocol/archive.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/ids.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/mod.rs`
- Test: `local-ios-agent/rust-core/tests/protocol_lifecycle.rs`

- [ ] **Step 1: Write lifecycle shell tests**

```rust
use local_ios_agent_runtime::protocol::{
    ArchiveId, BindingId, ComponentArchive, ComponentBinding, ComponentInstance, DefinitionId,
    InstanceId, SchemaVersion, SnapshotArchiveKind, SnapshotId, SnapshotRecord, SnapshotSource,
    SlotKey,
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
    .with_binding(BindingId::new("binding.model.primary"));

    assert_eq!(snapshot.source().as_str(), "profile.research");
    assert_eq!(snapshot.binding_ids().len(), 1);
}

#[test]
fn archive_links_to_snapshot_and_declares_archive_kind() {
    let archive = ComponentArchive::new(
        ArchiveId::new("archive.prompt.run_1"),
        SnapshotId::new("snapshot.run_1"),
        SnapshotArchiveKind::Prompt,
        SchemaVersion::new(1, 0),
    );

    assert_eq!(archive.snapshot_id().as_str(), "snapshot.run_1");
    assert_eq!(archive.kind(), SnapshotArchiveKind::Prompt);
}
```

- [ ] **Step 2: Implement protocol lifecycle shells**

Add stable IDs and immutable shell types for `ComponentInstance`, `ComponentBinding`, `SnapshotRecord`, and `ComponentArchive`. These types only model protocol ownership and source links; they must not import runtime, storage, provider adapter, or Swift bridge code.

- [ ] **Step 3: Run lifecycle tests**

Run:

```bash
cargo test --test protocol_lifecycle
```

Expected: lifecycle shell tests pass.

## Task 3: Add PluginModule and RuntimePluginRegistry

**Files:**
- Create: `local-ios-agent/rust-core/src/protocol/runtime_plugin_registry.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/plugin_module.rs`
- Test: `local-ios-agent/rust-core/tests/protocol_plugin_module.rs`

- [ ] **Step 1: Write plugin registration test**

```rust
use local_ios_agent_runtime::protocol::{
    BuiltinProviderPlugin, HostCapabilityManifest, PluginRegistryBuilder,
};

#[test]
fn plugin_module_registers_provider_and_freezes_runtime_registry() {
    let host = HostCapabilityManifest::all_supported();
    let mut builder = PluginRegistryBuilder::new(host);
    BuiltinProviderPlugin::openai_compatible().register(&mut builder).unwrap();

    let registry = builder.freeze().unwrap();

    assert!(registry.providers().contains("provider.openai_compatible"));
    assert!(registry.providers().is_frozen());
    assert!(registry.models().is_frozen());
    assert!(registry.inference_backends().is_frozen());
    assert!(registry.prompt_compilers().is_frozen());
    assert!(registry.tools().is_frozen());
    assert!(registry.memory().is_frozen());
    assert!(registry.context_policies().is_frozen());
    assert!(registry.voice().is_frozen());
}
```

- [ ] **Step 2: Run failing test**

Run:

```bash
cargo test --test protocol_plugin_module plugin_module_registers_provider_and_freezes_runtime_registry
```

Expected: unresolved `PluginRegistryBuilder`.

- [ ] **Step 3: Implement plugin module and runtime registry**

```rust
pub trait PluginModule: Send + Sync {
    fn module_id(&self) -> ModuleId;
    fn required_host_capabilities(&self) -> &'static [&'static str] { &[] }
    fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()>;
}

pub struct RuntimePluginRegistry {
    providers: TypedRegistry<ProviderDefinition>,
    models: TypedRegistry<ModelDefinition>,
    inference_backends: TypedRegistry<InferenceBackendDefinition>,
    prompt_compilers: TypedRegistry<PromptCompilerDefinition>,
    tools: TypedRegistry<ToolDefinition>,
    memory: TypedRegistry<MemoryDefinition>,
    context_policies: TypedRegistry<ContextPolicyDefinition>,
    voice: TypedRegistry<VoiceDefinition>,
}
```

Expose read-only accessors such as `providers()` and `inference_backends()`; do not expose public registry fields that can be reassigned after `freeze()`.

- [ ] **Step 4: Run plugin tests**

Run:

```bash
cargo test --test protocol_plugin_module
```

Expected: plugin registration test passes.

## Task 4: Add Compile-Time Plugin List and Host Capability Manifest

**Files:**
- Create: `local-ios-agent/rust-core/src/protocol/host_capability.rs`
- Modify: `local-ios-agent/rust-core/src/protocol/runtime_plugin_registry.rs`
- Test: `local-ios-agent/rust-core/tests/protocol_plugin_module.rs`

- [ ] **Step 1: Write host capability mismatch test**

```rust
use local_ios_agent_runtime::protocol::{
    BuiltinInferencePlugin, BuiltinProviderPlugin, HostCapabilityManifest,
    LegacyRuntimeAdapterPlugin, PluginRegistryBuilder, RegistryError, StaticPluginList,
    StaticPluginModule, StaticPluginRegistration,
};

#[test]
fn host_capability_manifest_blocks_unsupported_plugin() {
    let host = HostCapabilityManifest::new(["keychain", "network"]);
    let mut builder = PluginRegistryBuilder::new(host);

    let error = BuiltinInferencePlugin::llama_cpp().register(&mut builder).unwrap_err();

    assert!(matches!(error, RegistryError::MissingHostCapability(_)));
}

#[test]
fn static_plugin_list_records_feature_and_registers_in_order() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .with_cargo_feature("builtin-openai-compatible")
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("legacy.runtime_adapter"),
            Box::new(LegacyRuntimeAdapterPlugin::runtime_adapter()),
        ),
    ]);

    let registry = list.build_registry(host).unwrap();

    assert_eq!(list.modules()[0].module_id.as_str(), "builtin.provider.openai_compatible");
    assert_eq!(list.modules()[0].cargo_feature.as_deref(), Some("builtin-openai-compatible"));
    assert!(registry.providers().contains("provider.openai_compatible"));
    assert!(registry.inference_backends().contains("inference.legacy_runtime_adapter"));
}

#[test]
fn static_plugin_list_rejects_mismatched_module_metadata() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![StaticPluginRegistration::new(
        StaticPluginModule::new("wrong.module.id").requires_host_capability("network"),
        Box::new(BuiltinProviderPlugin::openai_compatible()),
    )]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(error, RegistryError::StaticPluginMetadataMismatch { .. }));
}

#[test]
fn static_plugin_list_rejects_duplicate_module_id_before_registration() {
    let host = HostCapabilityManifest::all_supported();
    let list = StaticPluginList::new(vec![
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
        StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ),
    ]);

    let error = list.build_registry(host).unwrap_err();

    assert!(matches!(error, RegistryError::DuplicatePluginModuleId(_)));
}

#[test]
fn static_plugin_feature_metadata_names_declared_cargo_features() {
    let manifest = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml"))
        .unwrap();
    let list = StaticPluginList::compiled();

    for module in list.modules() {
        if let Some(feature) = module.cargo_feature.as_deref() {
            assert!(manifest.contains(&format!("{feature} =")));
        }
    }
}

#[test]
fn compiled_list_includes_openai_provider_when_feature_is_enabled() {
    if !cfg!(feature = "builtin-openai-compatible") {
        return;
    }

    let list = StaticPluginList::compiled();
    let registry = list
        .build_registry(HostCapabilityManifest::all_supported())
        .unwrap();

    assert!(list
        .modules()
        .iter()
        .any(|module| module.module_id.as_str() == "builtin.provider.openai_compatible"));
    assert!(registry.providers().contains("provider.openai_compatible"));
}
```

- [ ] **Step 2: Implement manifest**

Add `HostCapabilityManifest` with named capabilities such as `native_inference`, `keychain`, and `network`. `PluginModule::register` must check the manifest before inserting definitions. Add `StaticPluginList`, `StaticPluginModule`, and `StaticPluginRegistration` so each compiled plugin can be traced to an actual Cargo feature declared in `Cargo.toml`, static module list order, and host capability checks. `StaticPluginList::build_registry` must reject duplicate module IDs and metadata whose `module_id` or required capabilities do not match the actual `PluginModule`. Include a legacy adapter module that registers through `PluginModule`; do not expose fixture-named constructors as the production API.

- [ ] **Step 3: Run manifest test**

Run:

```bash
cargo test --test protocol_plugin_module host_capability_manifest_blocks_unsupported_plugin
```

Expected: test passes.

## Task 5: Add Unknown Enum Decode Fixture

**Files:**
- Create: `local-ios-agent/rust-core/src/protocol/unknown_enum.rs`
- Test: `local-ios-agent/rust-core/tests/protocol_dto_unknown.rs`

- [ ] **Step 1: Write unknown enum decode test**

```rust
use local_ios_agent_runtime::protocol::ProviderKindDTO;

#[test]
fn dto_enum_decodes_unknown_value_without_crashing() {
    let dto: ProviderKindDTO = serde_json::from_str(r#""future_quantum_provider""#).unwrap();

    assert!(matches!(dto, ProviderKindDTO::Unknown(value) if value == "future_quantum_provider"));
}
```

- [ ] **Step 2: Implement unknown-safe DTO enum**

Implement custom `Deserialize` for DTO-facing enums so unknown strings become `Unknown(String)` instead of errors.

- [ ] **Step 3: Run unknown enum tests**

Run:

```bash
cargo test --test protocol_dto_unknown
```

Expected: unknown enum decode test passes.

## Verification

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test protocol_registry
cargo test --test protocol_lifecycle
cargo test --test protocol_plugin_module
cargo test --test protocol_dto_unknown
cargo test --features builtin-openai-compatible --test protocol_plugin_module
cargo test
```

## Self-Review

- `protocol` has no import from `core::runtime`, `memory::sqlite`, `ffi_bridge`, or inference C++.
- Duplicate IDs fail before freeze.
- Duplicate static plugin module IDs fail before registration.
- Freeze prevents late writes.
- Plugin module traits are object-safe.
- RuntimePluginRegistry freezes all typed registries.
- HostCapabilityManifest blocks unsupported compile-time plugins.
- Instance, Binding, Snapshot, and Archive have protocol-level shell types.
- DTO-facing enums preserve unknown values.
