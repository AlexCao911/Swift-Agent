pub mod archive;
pub mod binding;
pub mod definition;
pub mod host_capability;
pub mod ids;
pub mod instance;
pub mod plugin_module;
pub mod runtime_plugin_registry;
pub mod schema_version;
pub mod snapshot;
pub mod typed_registry;
pub mod unknown_enum;

pub use archive::{ComponentArchive, SnapshotArchiveKind};
pub use binding::{ComponentBinding, SlotKey};
pub use definition::DefinitionCompatibility;
pub use host_capability::{HostCapability, HostCapabilityManifest};
pub use ids::{ArchiveId, BindingId, DefinitionId, InstanceId, ModuleId, SnapshotId};
pub use instance::ComponentInstance;
pub use plugin_module::{
    BuiltinInferencePlugin, BuiltinProviderPlugin, ContextPolicyDefinition,
    InferenceBackendDefinition, LegacyRuntimeAdapterPlugin, MemoryDefinition, ModelDefinition,
    PluginModule, PromptCompilerDefinition, ProviderDefinition, ToolDefinition, VoiceDefinition,
};
pub use runtime_plugin_registry::{
    PluginRegistryBuilder, RuntimePluginRegistry, StaticPluginList, StaticPluginModule,
    StaticPluginRegistration,
};
pub use schema_version::SchemaVersion;
pub use snapshot::{SnapshotRecord, SnapshotSource};
pub use typed_registry::{ComponentDefinition, RegistryError, RegistryResult, TypedRegistry};
pub use unknown_enum::ProviderKindDTO;
