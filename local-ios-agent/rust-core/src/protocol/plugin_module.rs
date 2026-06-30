use super::{
    ComponentDefinition, DefinitionCompatibility, DefinitionId, ModuleId, PluginRegistryBuilder,
    RegistryError, RegistryResult, SchemaVersion,
};

pub trait PluginModule: Send + Sync {
    fn module_id(&self) -> ModuleId;
    fn required_host_capabilities(&self) -> &'static [&'static str] {
        &[]
    }
    fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()>;
}

macro_rules! protocol_definition {
    ($name:ident) => {
        #[derive(Clone, Debug, Eq, PartialEq)]
        pub struct $name {
            id: DefinitionId,
            display_name: String,
            schema_version: SchemaVersion,
            compatibility: DefinitionCompatibility,
        }

        impl $name {
            pub fn new(id: impl Into<String>) -> Self {
                let id = id.into();
                Self {
                    display_name: id.clone(),
                    id: DefinitionId::new(id),
                    schema_version: SchemaVersion::new(1, 0),
                    compatibility: DefinitionCompatibility::compatible(),
                }
            }

            pub fn with_display_name(mut self, display_name: impl Into<String>) -> Self {
                self.display_name = display_name.into();
                self
            }

            pub fn with_schema_version(mut self, schema_version: SchemaVersion) -> Self {
                self.schema_version = schema_version;
                self
            }

            pub fn with_compatibility(mut self, compatibility: DefinitionCompatibility) -> Self {
                self.compatibility = compatibility;
                self
            }
        }

        impl ComponentDefinition for $name {
            fn id(&self) -> DefinitionId {
                self.id.clone()
            }

            fn schema_version(&self) -> SchemaVersion {
                self.schema_version
            }

            fn display_name(&self) -> &str {
                &self.display_name
            }

            fn compatibility(&self) -> DefinitionCompatibility {
                self.compatibility.clone()
            }
        }
    };
}

protocol_definition!(ProviderDefinition);
protocol_definition!(ModelDefinition);
protocol_definition!(InferenceBackendDefinition);
protocol_definition!(PromptCompilerDefinition);
protocol_definition!(ToolDefinition);
protocol_definition!(MemoryDefinition);
protocol_definition!(ContextPolicyDefinition);
protocol_definition!(VoiceDefinition);

#[cfg(feature = "builtin-openai-compatible")]
#[derive(Clone, Debug)]
pub struct BuiltinProviderPlugin {
    module_id: ModuleId,
}

#[cfg(feature = "builtin-openai-compatible")]
impl BuiltinProviderPlugin {
    pub fn openai_compatible() -> Self {
        Self {
            module_id: ModuleId::new("builtin.provider.openai_compatible"),
        }
    }

    pub fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()> {
        PluginModule::register(self, builder)
    }
}

#[cfg(feature = "builtin-openai-compatible")]
impl PluginModule for BuiltinProviderPlugin {
    fn module_id(&self) -> ModuleId {
        self.module_id.clone()
    }

    fn required_host_capabilities(&self) -> &'static [&'static str] {
        &["network"]
    }

    fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()> {
        builder.require_host_capability("network")?;
        builder.register_provider(ProviderDefinition::new("provider.openai_compatible"))
    }
}

#[derive(Clone, Debug)]
pub struct BuiltinInferencePlugin {
    module_id: ModuleId,
    required_capability: &'static str,
}

impl BuiltinInferencePlugin {
    pub fn llama_cpp() -> Self {
        Self {
            module_id: ModuleId::new("builtin.inference.llama_cpp"),
            required_capability: "native_inference",
        }
    }

    pub fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()> {
        PluginModule::register(self, builder)
    }
}

impl PluginModule for BuiltinInferencePlugin {
    fn module_id(&self) -> ModuleId {
        self.module_id.clone()
    }

    fn required_host_capabilities(&self) -> &'static [&'static str] {
        &["native_inference"]
    }

    fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()> {
        if !builder.host_supports(self.required_capability) {
            return Err(RegistryError::MissingHostCapability(
                self.required_capability.to_string(),
            ));
        }

        builder.register_inference_backend(InferenceBackendDefinition::new("inference.llama_cpp"))
    }
}

#[derive(Clone, Debug)]
pub struct LegacyRuntimeAdapterPlugin {
    module_id: ModuleId,
}

impl LegacyRuntimeAdapterPlugin {
    pub fn runtime_adapter() -> Self {
        Self {
            module_id: ModuleId::new("legacy.runtime_adapter"),
        }
    }
}

impl PluginModule for LegacyRuntimeAdapterPlugin {
    fn module_id(&self) -> ModuleId {
        self.module_id.clone()
    }

    fn register(&self, builder: &mut PluginRegistryBuilder) -> RegistryResult<()> {
        builder.register_inference_backend(InferenceBackendDefinition::new(
            "inference.legacy_runtime_adapter",
        ))
    }
}
