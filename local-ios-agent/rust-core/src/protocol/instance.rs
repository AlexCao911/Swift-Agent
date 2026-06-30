use super::{DefinitionId, InstanceId, SchemaVersion};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentInstance {
    id: InstanceId,
    definition_id: DefinitionId,
    schema_version: SchemaVersion,
}

impl ComponentInstance {
    pub fn new(id: InstanceId, definition_id: DefinitionId, schema_version: SchemaVersion) -> Self {
        Self {
            id,
            definition_id,
            schema_version,
        }
    }

    pub fn id(&self) -> &InstanceId {
        &self.id
    }

    pub fn definition_id(&self) -> &DefinitionId {
        &self.definition_id
    }

    pub fn schema_version(&self) -> SchemaVersion {
        self.schema_version
    }
}
