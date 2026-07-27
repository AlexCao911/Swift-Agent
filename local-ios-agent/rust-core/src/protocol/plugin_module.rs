use super::{
    ComponentDefinition, DefinitionCompatibility, DefinitionId, ModuleId, PluginRegistryBuilder,
    RegistryResult, SchemaVersion,
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

protocol_definition!(PromptCompilerDefinition);
protocol_definition!(ToolDefinition);
protocol_definition!(MemoryDefinition);
protocol_definition!(ContextPolicyDefinition);
protocol_definition!(VoiceDefinition);
