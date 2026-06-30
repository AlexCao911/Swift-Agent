use std::collections::BTreeSet;

use super::{
    ContextPolicyDefinition, HostCapabilityManifest, InferenceBackendDefinition,
    LegacyRuntimeAdapterPlugin, MemoryDefinition, ModelDefinition, PluginModule,
    PromptCompilerDefinition, ProviderDefinition, RegistryError, RegistryResult, ToolDefinition,
    TypedRegistry, VoiceDefinition,
};

#[cfg(feature = "builtin-openai-compatible")]
use super::BuiltinProviderPlugin;

#[derive(Clone, Debug)]
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

impl RuntimePluginRegistry {
    pub fn providers(&self) -> &TypedRegistry<ProviderDefinition> {
        &self.providers
    }

    pub fn models(&self) -> &TypedRegistry<ModelDefinition> {
        &self.models
    }

    pub fn inference_backends(&self) -> &TypedRegistry<InferenceBackendDefinition> {
        &self.inference_backends
    }

    pub fn prompt_compilers(&self) -> &TypedRegistry<PromptCompilerDefinition> {
        &self.prompt_compilers
    }

    pub fn tools(&self) -> &TypedRegistry<ToolDefinition> {
        &self.tools
    }

    pub fn memory(&self) -> &TypedRegistry<MemoryDefinition> {
        &self.memory
    }

    pub fn context_policies(&self) -> &TypedRegistry<ContextPolicyDefinition> {
        &self.context_policies
    }

    pub fn voice(&self) -> &TypedRegistry<VoiceDefinition> {
        &self.voice
    }
}

#[derive(Clone, Debug)]
pub struct PluginRegistryBuilder {
    host: HostCapabilityManifest,
    providers: TypedRegistry<ProviderDefinition>,
    models: TypedRegistry<ModelDefinition>,
    inference_backends: TypedRegistry<InferenceBackendDefinition>,
    prompt_compilers: TypedRegistry<PromptCompilerDefinition>,
    tools: TypedRegistry<ToolDefinition>,
    memory: TypedRegistry<MemoryDefinition>,
    context_policies: TypedRegistry<ContextPolicyDefinition>,
    voice: TypedRegistry<VoiceDefinition>,
}

impl PluginRegistryBuilder {
    pub fn new(host: HostCapabilityManifest) -> Self {
        Self {
            host,
            providers: TypedRegistry::new(),
            models: TypedRegistry::new(),
            inference_backends: TypedRegistry::new(),
            prompt_compilers: TypedRegistry::new(),
            tools: TypedRegistry::new(),
            memory: TypedRegistry::new(),
            context_policies: TypedRegistry::new(),
            voice: TypedRegistry::new(),
        }
    }

    pub fn register_provider(&mut self, definition: ProviderDefinition) -> RegistryResult<()> {
        self.providers.insert(definition)
    }

    pub fn register_model(&mut self, definition: ModelDefinition) -> RegistryResult<()> {
        self.models.insert(definition)
    }

    pub fn register_inference_backend(
        &mut self,
        definition: InferenceBackendDefinition,
    ) -> RegistryResult<()> {
        self.inference_backends.insert(definition)
    }

    pub fn register_prompt_compiler(
        &mut self,
        definition: PromptCompilerDefinition,
    ) -> RegistryResult<()> {
        self.prompt_compilers.insert(definition)
    }

    pub fn register_tool(&mut self, definition: ToolDefinition) -> RegistryResult<()> {
        self.tools.insert(definition)
    }

    pub fn register_memory(&mut self, definition: MemoryDefinition) -> RegistryResult<()> {
        self.memory.insert(definition)
    }

    pub fn register_context_policy(
        &mut self,
        definition: ContextPolicyDefinition,
    ) -> RegistryResult<()> {
        self.context_policies.insert(definition)
    }

    pub fn register_voice(&mut self, definition: VoiceDefinition) -> RegistryResult<()> {
        self.voice.insert(definition)
    }

    pub fn require_host_capability(&self, capability: &str) -> RegistryResult<()> {
        if self.host_supports(capability) {
            Ok(())
        } else {
            Err(RegistryError::MissingHostCapability(capability.to_string()))
        }
    }

    pub fn host_supports(&self, capability: &str) -> bool {
        self.host.supports(capability)
    }

    pub fn freeze(mut self) -> RegistryResult<RuntimePluginRegistry> {
        self.providers.freeze();
        self.models.freeze();
        self.inference_backends.freeze();
        self.prompt_compilers.freeze();
        self.tools.freeze();
        self.memory.freeze();
        self.context_policies.freeze();
        self.voice.freeze();

        Ok(RuntimePluginRegistry {
            providers: self.providers,
            models: self.models,
            inference_backends: self.inference_backends,
            prompt_compilers: self.prompt_compilers,
            tools: self.tools,
            memory: self.memory,
            context_policies: self.context_policies,
            voice: self.voice,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CargoFeature {
    BuiltinOpenAICompatible,
}

impl CargoFeature {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::BuiltinOpenAICompatible => "builtin-openai-compatible",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StaticPluginModule {
    pub module_id: super::ModuleId,
    pub cargo_feature: Option<CargoFeature>,
    pub required_host_capabilities: Vec<String>,
}

impl StaticPluginModule {
    pub fn new(module_id: impl Into<String>) -> Self {
        Self {
            module_id: super::ModuleId::new(module_id),
            cargo_feature: None,
            required_host_capabilities: Vec::new(),
        }
    }

    pub fn with_cargo_feature(mut self, cargo_feature: CargoFeature) -> Self {
        self.cargo_feature = Some(cargo_feature);
        self
    }

    pub fn requires_host_capability(mut self, capability: impl Into<String>) -> Self {
        self.required_host_capabilities.push(capability.into());
        self
    }
}

pub struct StaticPluginRegistration {
    metadata: StaticPluginModule,
    plugin: Box<dyn PluginModule>,
}

impl StaticPluginRegistration {
    pub fn new(metadata: StaticPluginModule, plugin: Box<dyn PluginModule>) -> Self {
        Self { metadata, plugin }
    }
}

pub struct StaticPluginList {
    entries: Vec<StaticPluginRegistration>,
    modules: Vec<StaticPluginModule>,
}

impl StaticPluginList {
    pub fn new(entries: Vec<StaticPluginRegistration>) -> Self {
        let modules = entries.iter().map(|entry| entry.metadata.clone()).collect();
        Self { entries, modules }
    }

    pub fn compiled() -> Self {
        let mut entries = Vec::new();

        #[cfg(feature = "builtin-openai-compatible")]
        entries.push(StaticPluginRegistration::new(
            StaticPluginModule::new("builtin.provider.openai_compatible")
                .with_cargo_feature(CargoFeature::BuiltinOpenAICompatible)
                .requires_host_capability("network"),
            Box::new(BuiltinProviderPlugin::openai_compatible()),
        ));

        entries.push(StaticPluginRegistration::new(
            StaticPluginModule::new("legacy.runtime_adapter"),
            Box::new(LegacyRuntimeAdapterPlugin::runtime_adapter()),
        ));

        Self::new(entries)
    }

    pub fn modules(&self) -> &[StaticPluginModule] {
        &self.modules
    }

    pub fn build_registry(
        &self,
        host: HostCapabilityManifest,
    ) -> RegistryResult<RuntimePluginRegistry> {
        let mut builder = PluginRegistryBuilder::new(host);
        let mut module_ids = BTreeSet::new();

        for entry in &self.entries {
            if !module_ids.insert(entry.metadata.module_id.clone()) {
                return Err(RegistryError::DuplicatePluginModuleId(
                    entry.metadata.module_id.clone(),
                ));
            }

            let actual_module_id = entry.plugin.module_id();
            if entry.metadata.module_id != actual_module_id {
                return Err(RegistryError::StaticPluginMetadataMismatch {
                    expected: entry.metadata.module_id.as_str().to_string(),
                    actual: actual_module_id.as_str().to_string(),
                });
            }

            let plugin_capabilities: BTreeSet<&str> = entry
                .plugin
                .required_host_capabilities()
                .iter()
                .copied()
                .collect();
            let metadata_capabilities: BTreeSet<&str> = entry
                .metadata
                .required_host_capabilities
                .iter()
                .map(String::as_str)
                .collect();

            for capability in plugin_capabilities.difference(&metadata_capabilities) {
                return Err(RegistryError::StaticPluginCapabilityMismatch {
                    module_id: actual_module_id.as_str().to_string(),
                    capability: (*capability).to_string(),
                });
            }

            for capability in metadata_capabilities.difference(&plugin_capabilities) {
                return Err(RegistryError::StaticPluginCapabilityMismatch {
                    module_id: actual_module_id.as_str().to_string(),
                    capability: (*capability).to_string(),
                });
            }

            for capability in &entry.metadata.required_host_capabilities {
                builder.require_host_capability(capability)?;
            }
            entry.plugin.register(&mut builder)?;
        }
        builder.freeze()
    }
}
