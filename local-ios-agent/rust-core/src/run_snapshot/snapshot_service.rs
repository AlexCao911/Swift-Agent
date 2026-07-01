use std::fmt;
use std::sync::{Arc, Mutex};

use crate::model::InMemoryModelBindingCatalog;
use crate::run_snapshot::{
    ResolvedRunSnapshot, RunSnapshotPreview, RunSnapshotRepository, RunSnapshotResolveInput,
    RunSnapshotResolver, RunSnapshotSourceCatalog, StartRunRequest,
};
use crate::security::{CredentialRefResolver, PermissionState, SecurityPermissionService};
use crate::storage::{
    InMemoryTransactionRunner, StorageError, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
};
use crate::user_customization::{ComponentCatalogService, InMemoryAgentProfileRepository};

pub type RunSnapshotResult<T> = Result<T, RunSnapshotError>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotError {
    code: String,
    message: String,
}

pub struct RunSnapshotService {
    sources: RunSnapshotSourceCatalog,
    resolver: RunSnapshotResolver,
    repository: RunSnapshotRepository,
    runner: Box<dyn TransactionRunner>,
    runtime_started: bool,
}

struct SnapshotPersistOperation<'a> {
    sources: &'a RunSnapshotSourceCatalog,
    resolver: &'a RunSnapshotResolver,
    repository: RunSnapshotRepository,
    preview: RunSnapshotPreview,
    committed_snapshot: Arc<Mutex<Option<ResolvedRunSnapshot>>>,
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
        sources: RunSnapshotSourceCatalog,
        repository: RunSnapshotRepository,
        runner: Box<dyn TransactionRunner>,
    ) -> Self {
        let resolver = RunSnapshotResolver::new(sources.clone());
        Self {
            sources,
            resolver,
            repository,
            runner,
            runtime_started: false,
        }
    }

    pub fn from_real_repositories(
        profile_repository: InMemoryAgentProfileRepository,
        component_catalog: ComponentCatalogService,
        model_catalog: InMemoryModelBindingCatalog,
        security: Arc<dyn SecurityPermissionService>,
        credential_resolver: Arc<dyn CredentialRefResolver>,
        runner: Box<dyn TransactionRunner>,
    ) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::new(
                profile_repository,
                component_catalog,
                model_catalog,
                security,
                credential_resolver,
            ),
            RunSnapshotRepository::default(),
            runner,
        )
    }

    pub fn fixture() -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_profile_with_persona_and_model(),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn fixture_with_profile_version(profile_version: u64) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_with_profile_version(profile_version),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn fixture_with_component_entity_version(entity_version: u64) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_with_component_entity_version(entity_version),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn fixture_with_model_catalog_version(catalog_version: u64) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_with_model_catalog_version(catalog_version),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn fixture_with_model_id_at_same_catalog_version(model_id: impl Into<String>) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_with_model_id_at_same_catalog_version(model_id),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn fixture_with_permission_state(permission_state: PermissionState) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_with_permission_state(permission_state),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn fixture_without_credentials() -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_without_credentials(),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
    }

    pub fn preview(&self, request: StartRunRequest) -> RunSnapshotResult<RunSnapshotPreview> {
        let trusted_host_state = self.sources.capture_trusted_host_state(&request)?;
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
        let committed_snapshot = Arc::new(Mutex::new(None));
        let mut operation = SnapshotPersistOperation {
            sources: &self.sources,
            resolver: &self.resolver,
            repository: self.repository.clone(),
            preview,
            committed_snapshot: committed_snapshot.clone(),
        };

        self.runner
            .run(TransactionName::new("run_snapshot.persist"), &mut operation)?;

        let result = committed_snapshot
            .lock()
            .expect("committed snapshot mutex poisoned")
            .clone()
            .ok_or_else(|| {
                RunSnapshotError::new(
                    "snapshot.persist_failed",
                    "run snapshot persist operation did not produce a snapshot",
                )
            });
        result
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
                self.sources
                    .capture_trusted_host_state(self.preview.request())
                    .map_err(|error| {
                        StorageError::new(error.code().to_string(), error.to_string())
                    })?,
            ))
            .map_err(|error| StorageError::new(error.code().to_string(), error.to_string()))?;
        ensure_preview_still_current(self.preview.snapshot(), &current)
            .map_err(|error| StorageError::new(error.code().to_string(), error.to_string()))?;
        if !current.readiness_report().is_ready() {
            return Err(StorageError::new(
                "snapshot.not_ready",
                "run snapshot cannot be persisted until readiness issues are resolved",
            ));
        }
        self.repository
            .stage_snapshot(tx, current, self.committed_snapshot.clone())?;
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

    if preview.model_binding() != current.model_binding() {
        return Err(RunSnapshotError::new(
            "snapshot.model_version_conflict",
            "model binding changed between snapshot preview and persist",
        ));
    }

    Ok(())
}
