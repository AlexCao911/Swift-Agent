use super::{ArchiveId, SchemaVersion, SnapshotId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotArchiveKind {
    Prompt,
    Context,
    ModelCall,
    ToolInvocation,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentArchive {
    id: ArchiveId,
    snapshot_id: SnapshotId,
    kind: SnapshotArchiveKind,
    schema_version: SchemaVersion,
}

impl ComponentArchive {
    pub fn new(
        id: ArchiveId,
        snapshot_id: SnapshotId,
        kind: SnapshotArchiveKind,
        schema_version: SchemaVersion,
    ) -> Self {
        Self {
            id,
            snapshot_id,
            kind,
            schema_version,
        }
    }

    pub fn id(&self) -> &ArchiveId {
        &self.id
    }

    pub fn snapshot_id(&self) -> &SnapshotId {
        &self.snapshot_id
    }

    pub fn kind(&self) -> SnapshotArchiveKind {
        self.kind
    }

    pub fn schema_version(&self) -> SchemaVersion {
        self.schema_version
    }
}
