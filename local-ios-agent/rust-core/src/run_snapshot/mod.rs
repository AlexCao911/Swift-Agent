mod preparation_preview;
mod resolved_bindings;
mod resolver;
mod snapshot;
mod snapshot_service;

pub(crate) use preparation_preview::{derive_authoritative_preparation, FrozenGenerationTurn};
pub use resolved_bindings::{
    OpaqueHostBindingCrossLink, ResolvedComponentBinding, ResolvedHostSlotBinding,
    ResolvedMemoryBinding, ResolvedToolBinding, ResolvedVoiceBinding,
};
pub use resolver::{RunSnapshotRepository, RunSnapshotResolver, RunSnapshotSourceCatalog};
pub use snapshot::{
    PersistedResolvedHostSlotBinding, PersistedResolvedRunSnapshotV2, PersistedRunSnapshotError,
    ResolvedRunSnapshot, RunSnapshotId, RunSnapshotPreview, RunSnapshotReadinessIssue,
    RunSnapshotReadinessReport, RunSnapshotResolveInput, RunUserIntent, StartRunRequest,
};
pub use snapshot_service::{
    RunPreparationService, RunSnapshotError, RunSnapshotResult, RunSnapshotService,
};
