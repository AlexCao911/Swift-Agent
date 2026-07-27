use std::collections::BTreeSet;

use super::{
    ContextPolicyDefinition, HostCapabilityManifest, MemoryDefinition, PluginModule,
    PromptCompilerDefinition, RegistryError, RegistryResult, ToolDefinition, TypedRegistry,
    VoiceDefinition,
};

#[derive(Clone, Debug)]
pub struct RuntimePluginRegistry {
    prompt_compilers: TypedRegistry<PromptCompilerDefinition>,
    tools: TypedRegistry<ToolDefinition>,
    memory: TypedRegistry<MemoryDefinition>,
    context_policies: TypedRegistry<ContextPolicyDefinition>,
    voice: TypedRegistry<VoiceDefinition>,
}

impl RuntimePluginRegistry {
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
            prompt_compilers: TypedRegistry::new(),
            tools: TypedRegistry::new(),
            memory: TypedRegistry::new(),
            context_policies: TypedRegistry::new(),
            voice: TypedRegistry::new(),
        }
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
        if self.host.supports(capability) {
            Ok(())
        } else {
            Err(RegistryError::MissingHostCapability(capability.to_string()))
        }
    }

    pub fn host_supports(&self, capability: &str) -> bool {
        self.host.supports(capability)
    }

    pub fn freeze(mut self) -> RegistryResult<RuntimePluginRegistry> {
        self.prompt_compilers.freeze();
        self.tools.freeze();
        self.memory.freeze();
        self.context_policies.freeze();
        self.voice.freeze();
        Ok(RuntimePluginRegistry {
            prompt_compilers: self.prompt_compilers,
            tools: self.tools,
            memory: self.memory,
            context_policies: self.context_policies,
            voice: self.voice,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StaticPluginModule {
    pub module_id: super::ModuleId,
    pub required_host_capabilities: Vec<String>,
}

impl StaticPluginModule {
    pub fn new(module_id: impl Into<String>) -> Self {
        Self {
            module_id: super::ModuleId::new(module_id),
            required_host_capabilities: Vec::new(),
        }
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
        Self::new(Vec::new())
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
            if plugin_capabilities != metadata_capabilities {
                let capability = plugin_capabilities
                    .symmetric_difference(&metadata_capabilities)
                    .next()
                    .copied()
                    .unwrap_or_default();
                return Err(RegistryError::StaticPluginCapabilityMismatch {
                    module_id: actual_module_id.as_str().to_string(),
                    capability: capability.to_string(),
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
