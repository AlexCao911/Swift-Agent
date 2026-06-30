use super::{BindingId, SchemaVersion, SnapshotId};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotSource(String);

impl SnapshotSource {
    pub fn agent_profile(profile_id: impl Into<String>) -> Self {
        Self(profile_id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotRecord {
    id: SnapshotId,
    source: SnapshotSource,
    schema_version: SchemaVersion,
    binding_ids: Vec<BindingId>,
}

impl SnapshotRecord {
    pub fn new(id: SnapshotId, source: SnapshotSource, schema_version: SchemaVersion) -> Self {
        Self {
            id,
            source,
            schema_version,
            binding_ids: Vec::new(),
        }
    }

    pub fn with_binding(mut self, binding_id: BindingId) -> Self {
        self.binding_ids.push(binding_id);
        self
    }

    pub fn id(&self) -> &SnapshotId {
        &self.id
    }

    pub fn source(&self) -> &SnapshotSource {
        &self.source
    }

    pub fn schema_version(&self) -> SchemaVersion {
        self.schema_version
    }

    pub fn binding_ids(&self) -> &[BindingId] {
        &self.binding_ids
    }
}
