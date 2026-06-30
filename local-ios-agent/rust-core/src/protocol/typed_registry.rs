use std::collections::BTreeMap;

use super::{DefinitionCompatibility, DefinitionId, SchemaVersion};

pub type RegistryResult<T> = Result<T, RegistryError>;

#[derive(Debug, Eq, PartialEq)]
pub enum RegistryError {
    DuplicateDefinitionId(DefinitionId),
    Frozen,
    IncompatibleDefinition {
        id: DefinitionId,
        reason: String,
    },
    MissingHostCapability(String),
    StaticPluginMetadataMismatch {
        expected: String,
        actual: String,
    },
    StaticPluginCapabilityMismatch {
        module_id: String,
        capability: String,
    },
    DuplicatePluginModuleId(super::ModuleId),
}

pub trait ComponentDefinition {
    fn id(&self) -> DefinitionId;
    fn schema_version(&self) -> SchemaVersion;
    fn display_name(&self) -> &str;
    fn compatibility(&self) -> DefinitionCompatibility;
}

#[derive(Clone, Debug, Default)]
pub struct TypedRegistry<T: ComponentDefinition> {
    definitions: BTreeMap<DefinitionId, T>,
    frozen: bool,
}

impl<T: ComponentDefinition> TypedRegistry<T> {
    pub fn new() -> Self {
        Self {
            definitions: BTreeMap::new(),
            frozen: false,
        }
    }

    pub fn insert(&mut self, definition: T) -> RegistryResult<()> {
        if self.frozen {
            return Err(RegistryError::Frozen);
        }

        let compatibility = definition.compatibility();
        if !compatibility.is_compatible() {
            return Err(RegistryError::IncompatibleDefinition {
                id: definition.id(),
                reason: compatibility.reason().unwrap_or("").to_string(),
            });
        }

        let id = definition.id();
        if self.definitions.contains_key(&id) {
            return Err(RegistryError::DuplicateDefinitionId(id));
        }

        self.definitions.insert(id, definition);
        Ok(())
    }

    pub fn freeze(&mut self) {
        self.frozen = true;
    }

    pub fn is_frozen(&self) -> bool {
        self.frozen
    }

    pub fn contains(&self, id: &str) -> bool {
        self.definitions
            .keys()
            .any(|definition_id| definition_id.as_str() == id)
    }

    pub fn len(&self) -> usize {
        self.definitions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.definitions.is_empty()
    }
}
