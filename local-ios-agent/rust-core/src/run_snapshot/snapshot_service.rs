use std::fmt;

use crate::run_snapshot::{
    ResolvedRunSnapshot, RunSnapshotPreview, RunSnapshotRepository, RunSnapshotResolveInput,
    RunSnapshotResolver, StartRunRequest,
};
use crate::storage::{
    InMemoryTransactionRunner, StorageError, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
};

pub type RunSnapshotResult<T> = Result<T, RunSnapshotError>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotError {
    code: String,
    message: String,
}

pub struct RunSnapshotService {
    resolver: RunSnapshotResolver,
    repository: RunSnapshotRepository,
    runner: Box<dyn TransactionRunner>,
    runtime_started: bool,
}

struct SnapshotPersistOperation<'a> {
    resolver: &'a RunSnapshotResolver,
    repository: RunSnapshotRepository,
    preview: RunSnapshotPreview,
    result: Option<ResolvedRunSnapshot>,
}

impl RunSnapshotError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for RunSnapshotError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RunSnapshotError {}

impl From<StorageError> for RunSnapshotError {
    fn from(error: StorageError) -> Self {
        Self::new(error.code().to_string(), error.to_string())
    }
}

impl RunSnapshotService {
    pub fn new(
        resolver: RunSnapshotResolver,
        repository: RunSnapshotRepository,
        runner: Box<dyn TransactionRunner>,
    ) -> Self {
        Self {
            resolver,
            repository,
            runner,
            runtime_started: false,
        }
    }

    pub fn fixture() -> Self {
        let repository = RunSnapshotRepository::fixture_profile_with_persona_and_model();
        Self::new(
            RunSnapshotResolver::new(repository.clone()),
            repository,
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn preview(&self, request: StartRunRequest) -> RunSnapshotResult<RunSnapshotPreview> {
        let trusted_host_state = self.repository.capture_trusted_host_state(&request)?;
        let snapshot = self.resolver.resolve(RunSnapshotResolveInput::new(
            request.clone(),
            trusted_host_state,
        ))?;
        Ok(RunSnapshotPreview::new(request, snapshot))
    }

    pub fn resolve_and_persist(
        &self,
        request: StartRunRequest,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        let preview = self.preview(request)?;
        self.resolve_preview_and_persist(preview)
    }

    pub fn resolve_preview_and_persist(
        &self,
        preview: RunSnapshotPreview,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        let mut operation = SnapshotPersistOperation {
            resolver: &self.resolver,
            repository: self.repository.clone(),
            preview,
            result: None,
        };

        self.runner
            .run(TransactionName::new("run_snapshot.persist"), &mut operation)?;

        operation.result.ok_or_else(|| {
            RunSnapshotError::new(
                "snapshot.persist_failed",
                "run snapshot persist operation did not produce a snapshot",
            )
        })
    }

    pub fn repository(&self) -> RunSnapshotRepository {
        self.repository.clone()
    }

    pub fn runtime_was_started(&self) -> bool {
        self.runtime_started
    }
}

impl TransactionOperation for SnapshotPersistOperation<'_> {
    fn execute(&mut self, tx: &mut UnitOfWork) -> crate::storage::StorageResult<()> {
        let current = self
            .resolver
            .resolve(RunSnapshotResolveInput::new(
                self.preview.request().clone(),
                self.repository
                    .capture_trusted_host_state(self.preview.request())
                    .map_err(|error| {
                        StorageError::new(error.code().to_string(), error.to_string())
                    })?,
            ))
            .map_err(|error| StorageError::new(error.code().to_string(), error.to_string()))?;
        ensure_preview_still_current(self.preview.snapshot(), &current)
            .map_err(|error| StorageError::new(error.code().to_string(), error.to_string()))?;
        self.repository.stage_snapshot(tx, current.clone())?;
        self.result = Some(current);
        Ok(())
    }
}

fn ensure_preview_still_current(
    preview: &ResolvedRunSnapshot,
    current: &ResolvedRunSnapshot,
) -> RunSnapshotResult<()> {
    if preview.profile_version() != current.profile_version() {
        return Err(RunSnapshotError::new(
            "snapshot.profile_version_conflict",
            "agent profile changed between snapshot preview and persist",
        ));
    }

    if preview.component_versions().len() != current.component_versions().len()
        || preview
            .component_versions()
            .iter()
            .zip(current.component_versions())
            .any(|(preview, current)| {
                preview.version_id() != current.version_id()
                    || preview.entity_version() != current.entity_version()
            })
    {
        return Err(RunSnapshotError::new(
            "snapshot.component_version_conflict",
            "component version changed between snapshot preview and persist",
        ));
    }

    if preview.model_binding().binding_id() != current.model_binding().binding_id()
        || preview.model_binding().catalog_version() != current.model_binding().catalog_version()
    {
        return Err(RunSnapshotError::new(
            "snapshot.model_version_conflict",
            "model binding changed between snapshot preview and persist",
        ));
    }

    Ok(())
}
