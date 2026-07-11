use std::fmt;
use std::sync::{Arc, Mutex};

use crate::canonical_digest::CanonicalDigestV1;
use crate::llm_contracts::{
    HostAttestation, PreparationAbortReason, PreparationError, PreparedSessionCleanupEnvelope,
    PreparedSessionClosedReceipt, PreparedSessionRegistration, RenewalReplay,
    RunPreparationPreview, RunPreparationRecord, RunPreparationRequest, RunPreparationState,
};
use crate::model::InMemoryModelBindingCatalog;
use crate::run_snapshot::{
    ResolvedRunSnapshot, RunSnapshotPreview, RunSnapshotRepository, RunSnapshotResolveInput,
    RunSnapshotResolver, RunSnapshotSourceCatalog, StartRunRequest,
};
use crate::security::{CredentialRefResolver, PermissionState, SecurityPermissionService};
use crate::storage::agent_os_state::SharedAgentOSStateStore;
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

#[derive(Clone)]
pub struct RunPreparationService {
    state_store: SharedAgentOSStateStore,
    host_process_epoch: String,
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

impl RunPreparationService {
    const RENEWAL_MILLIS: u64 = 5 * 60 * 1_000;
    const TOTAL_LEASE_MILLIS: u64 = 30 * 60 * 1_000;

    pub fn new(
        state_store: SharedAgentOSStateStore,
        host_process_epoch: impl Into<String>,
    ) -> Self {
        Self {
            state_store,
            host_process_epoch: host_process_epoch.into(),
        }
    }

    pub fn preview_run(
        &self,
        request: RunPreparationRequest,
        now_millis: u64,
    ) -> Result<RunPreparationPreview, PreparationError> {
        if let Some(existing) = self.state_store.with_preparation(|store| {
            Ok(store
                .list_run_preparations()?
                .into_iter()
                .find(|record| record.idempotency_key() == request.idempotency_key()))
        })? {
            if existing.preview().preparation_id() == request.preparation_id()
                && existing.preview().proposed_run_id() == request.proposed_run_id()
                && existing.preview().binding() == request.binding()
            {
                return Ok(existing.preview().clone());
            }
            return Err(PreparationError::new(
                "preparation.idempotency_conflict",
                "preview idempotency key was replayed with different frozen input",
            ));
        }
        let expiration = now_millis
            .checked_add(Self::RENEWAL_MILLIS)
            .ok_or_else(time_overflow)?;
        let deadline = now_millis
            .checked_add(Self::TOTAL_LEASE_MILLIS)
            .ok_or_else(time_overflow)?;
        let binding_digest = digest("preparation-binding:v1", &request)?;
        let (token, token_digest) = new_token(
            request.preparation_id(),
            request.proposed_run_id(),
            1,
            now_millis,
        )?;

        self.state_store.with_preparation_mut(|store| {
            let lease = store
                .acquire_preparation(
                    request.preparation_id(),
                    &self.host_process_epoch,
                    expiration,
                )
                .map_err(preparation_lease_error)?;
            let preview = RunPreparationPreview::new(
                &request,
                token,
                token_digest,
                binding_digest,
                self.host_process_epoch.clone(),
                lease.generation(),
                expiration,
                deadline,
            );
            let record =
                RunPreparationRecord::new(request.idempotency_key().to_string(), preview.clone());
            match store.create_run_preparation(record) {
                Ok(_) => Ok(preview),
                Err(error) => {
                    let _ = store
                        .begin_release(
                            lease.generation(),
                            request.preparation_id(),
                            &self.host_process_epoch,
                        )
                        .and_then(|_| {
                            store.complete_release(lease.generation(), &self.host_process_epoch)
                        });
                    Err(error)
                }
            }
        })
    }

    pub fn renew_preparation(
        &self,
        token: &str,
        binding_digest: &str,
        idempotency_key: &str,
        now_millis: u64,
    ) -> Result<RunPreparationPreview, PreparationError> {
        self.state_store.with_preparation_mut(|store| {
            let mut record = store
                .active_run_preparation()?
                .ok_or_else(preparation_not_found)?;
            if token != record.preview().token() {
                if let Some(replay) = record.renewals().get(token) {
                    if replay.idempotency_key() == idempotency_key
                        && replay.preview().binding_digest() == binding_digest
                    {
                        return Ok(replay.preview().clone());
                    }
                }
                return Err(PreparationError::new(
                    "preparation.token_stale",
                    "preparation token was rotated or does not belong to the active preparation",
                ));
            }
            if let Err(error) = validate_token(
                &record,
                token,
                binding_digest,
                &self.host_process_epoch,
                now_millis,
            ) {
                if error.code() == "preparation.token_expired" {
                    expire_record(store, record)?;
                }
                return Err(error);
            }
            if now_millis >= record.preview().total_deadline_millis() {
                return Err(token_expired());
            }
            let expiration = now_millis
                .checked_add(Self::RENEWAL_MILLIS)
                .ok_or_else(time_overflow)?
                .min(record.preview().total_deadline_millis());
            let next_generation = record.preview().token_generation() + 1;
            let (next_token, next_digest) = new_token(
                record.preview().preparation_id(),
                record.preview().proposed_run_id(),
                next_generation,
                now_millis,
            )?;
            let renewed = record
                .preview()
                .renewed(next_token, next_digest, expiration);
            let expected_state = record.state();
            record.renewals_mut().insert(
                token.to_string(),
                RenewalReplay::new(idempotency_key.to_string(), renewed.clone()),
            );
            *record.preview_mut() = renewed.clone();
            store.save_run_preparation(expected_state, record)?;
            Ok(renewed)
        })
    }

    pub fn register_prepared_session(
        &self,
        token: &str,
        registration: PreparedSessionRegistration,
        now_millis: u64,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.state_store.with_preparation_mut(|store| {
            let mut record = store
                .active_run_preparation()?
                .ok_or_else(preparation_not_found)?;
            if let Err(error) = validate_token(
                &record,
                token,
                record.preview().binding_digest(),
                &self.host_process_epoch,
                now_millis,
            ) {
                if error.code() == "preparation.token_expired" {
                    expire_record(store, record)?;
                }
                return Err(error);
            }
            if let Some(existing) = record.registration() {
                return if existing == &registration {
                    Ok(record)
                } else {
                    Err(PreparationError::new(
                        "preparation.registration_conflict",
                        "prepared session registration was replayed with different identity",
                    ))
                };
            }
            if registration.preparation_id() != record.preview().preparation_id()
                || registration.proposed_run_id() != record.preview().proposed_run_id()
                || registration.host_process_epoch() != self.host_process_epoch
            {
                return Err(PreparationError::new(
                    "preparation.registration_mismatch",
                    "prepared session registration does not match the preparation identity",
                ));
            }
            record.register(registration);
            store.save_run_preparation(RunPreparationState::Pending, record)
        })
    }

    pub fn commit_start(
        &self,
        token: &str,
        attestation: HostAttestation,
        now_millis: u64,
    ) -> Result<(), PreparationError> {
        let record = self
            .state_store
            .with_preparation(|store| store.active_run_preparation())?
            .ok_or_else(preparation_not_found)?;
        if let Err(error) = validate_token(
            &record,
            token,
            record.preview().binding_digest(),
            &self.host_process_epoch,
            now_millis,
        ) {
            if error.code() == "preparation.token_expired" {
                self.begin_abort_preparation(
                    record.preview().preparation_id(),
                    None,
                    &format!("token-expired:{}", record.preview().preparation_id()),
                    PreparationAbortReason::TokenExpired,
                )?;
            }
            return Err(error);
        }
        let registration = record.registration().ok_or_else(|| {
            PreparationError::new(
                "preparation.session_not_registered",
                "commit requires an exact prepared-session registration",
            )
        })?;
        if attestation.registration() != registration
            || attestation.preparation_binding_digest() != record.preview().binding_digest()
            || attestation.expiration_millis() < now_millis
        {
            self.begin_abort_preparation(
                record.preview().preparation_id(),
                Some(token),
                &format!("commit-rejected:{}", record.preview().preparation_id()),
                PreparationAbortReason::CommitRejected,
            )?;
            return Err(PreparationError::new(
                "preparation.host_attestation_mismatch",
                "host attestation does not match the registered prepared session",
            ));
        }
        self.begin_abort_preparation(
            record.preview().preparation_id(),
            Some(token),
            &format!(
                "phase-one-nonrunnable:{}",
                record.preview().preparation_id()
            ),
            PreparationAbortReason::CommitRejected,
        )?;
        Err(PreparationError::new(
            "execution.host_slot_v2_not_runnable",
            "host-backed LLM execution remains disabled in Phase 1",
        ))
    }

    pub fn begin_abort_preparation(
        &self,
        preparation_id: &str,
        token: Option<&str>,
        idempotency_key: &str,
        reason: PreparationAbortReason,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.state_store.with_preparation_mut(|store| {
            let mut record = store
                .run_preparation(preparation_id)?
                .ok_or_else(preparation_not_found)?;
            if matches!(
                record.state(),
                RunPreparationState::Aborting | RunPreparationState::Closed
            ) {
                return Ok(record);
            }
            if reason != PreparationAbortReason::TokenExpired
                && token != Some(record.preview().token())
            {
                return Err(PreparationError::new(
                    "preparation.token_stale",
                    "abort token does not match the current preparation token",
                ));
            }
            let cleanup = record
                .registration()
                .map(|registration| make_cleanup(registration, reason))
                .transpose()?;
            let has_session = cleanup.is_some();
            record.abort(idempotency_key.to_string(), cleanup);
            store.abort_run_preparation(record, has_session)
        })
    }

    pub fn confirm_prepared_session_closed(
        &self,
        receipt: PreparedSessionClosedReceipt,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.state_store.with_preparation_mut(|store| {
            let mut record = store
                .run_preparation(receipt.preparation_id())?
                .ok_or_else(preparation_not_found)?;
            if record.state() == RunPreparationState::Closed {
                return if record.closed_receipt() == Some(&receipt) {
                    Ok(record)
                } else {
                    Err(close_mismatch())
                };
            }
            let cleanup = record.cleanup().ok_or_else(close_mismatch)?;
            if !receipt.matches_cleanup(cleanup) {
                return Err(close_mismatch());
            }
            record.close(receipt);
            store.close_run_preparation(record)
        })
    }

    pub fn preparation(
        &self,
        preparation_id: &str,
    ) -> Result<Option<RunPreparationRecord>, PreparationError> {
        self.state_store
            .with_preparation(|store| store.run_preparation(preparation_id))
    }

    pub fn recover_old_epoch(
        &self,
        current_host_epoch: &str,
    ) -> Result<Vec<String>, PreparationError> {
        let records = self
            .state_store
            .with_preparation(|store| store.list_run_preparations())?;
        let mut recovered = Vec::new();
        for mut record in records.into_iter().filter(|record| {
            record.state() != RunPreparationState::Closed
                && record.preview().host_process_epoch() != current_host_epoch
        }) {
            let expected = record.state();
            self.state_store
                .with_mut(|store| store.recover_old_epoch(current_host_epoch))
                .map_err(preparation_lease_error)?;
            record.close_for_epoch_end();
            let id = record.preview().preparation_id().to_string();
            self.state_store
                .with_preparation_mut(|store| store.save_run_preparation(expected, record))?;
            recovered.push(id);
        }
        recovered.sort();
        Ok(recovered)
    }
}

fn validate_token(
    record: &RunPreparationRecord,
    token: &str,
    binding_digest: &str,
    host_epoch: &str,
    now_millis: u64,
) -> Result<(), PreparationError> {
    if token != record.preview().token() {
        return Err(PreparationError::new(
            "preparation.token_stale",
            "preparation token is not current",
        ));
    }
    if binding_digest != record.preview().binding_digest()
        || host_epoch != record.preview().host_process_epoch()
    {
        return Err(PreparationError::new(
            "preparation.binding_mismatch",
            "preparation binding digest or host epoch changed",
        ));
    }
    if now_millis >= record.preview().expiration_millis() {
        return Err(token_expired());
    }
    Ok(())
}

fn new_token(
    preparation_id: &str,
    proposed_run_id: &str,
    generation: u64,
    now_millis: u64,
) -> Result<(String, String), PreparationError> {
    use std::sync::atomic::{AtomicU64, Ordering};
    #[derive(serde::Serialize)]
    struct TokenDocument<'a> {
        preparation_id: &'a str,
        proposed_run_id: &'a str,
        generation: u64,
        now_millis: u64,
        nonce: u64,
    }
    static NEXT_NONCE: AtomicU64 = AtomicU64::new(1);
    let document = TokenDocument {
        preparation_id,
        proposed_run_id,
        generation,
        now_millis,
        nonce: NEXT_NONCE.fetch_add(1, Ordering::Relaxed),
    };
    let token = digest("preparation-token:v1", &document)?;
    let token_digest = digest("preparation-token:v1", &token)?;
    Ok((token, token_digest))
}

fn make_cleanup(
    registration: &PreparedSessionRegistration,
    reason: PreparationAbortReason,
) -> Result<PreparedSessionCleanupEnvelope, PreparationError> {
    #[derive(serde::Serialize)]
    struct CommandIdentity<'a> {
        preparation_id: &'a str,
        proposed_run_id: &'a str,
        session_handle: &'a str,
        registration_digest: &'a str,
    }
    let identity = CommandIdentity {
        preparation_id: registration.preparation_id(),
        proposed_run_id: registration.proposed_run_id(),
        session_handle: registration.session_handle(),
        registration_digest: registration.registration_digest(),
    };
    let command_id = digest("prepared-session-cleanup-command:v1", &identity)?;
    let draft = PreparedSessionCleanupEnvelope::new(
        command_id.clone(),
        registration,
        reason,
        String::new(),
    );
    let command_digest = digest("prepared-session-cleanup-command:v1", &draft)?;
    Ok(PreparedSessionCleanupEnvelope::new(
        command_id,
        registration,
        reason,
        command_digest,
    ))
}

fn expire_record(
    store: &mut dyn crate::storage::agent_os_state::AgentOSStateRepository,
    mut record: RunPreparationRecord,
) -> Result<(), PreparationError> {
    let cleanup = record
        .registration()
        .map(|registration| make_cleanup(registration, PreparationAbortReason::TokenExpired))
        .transpose()?;
    let has_session = cleanup.is_some();
    let key = format!("token-expired:{}", record.preview().preparation_id());
    record.abort(key, cleanup);
    store.abort_run_preparation(record, has_session)?;
    Ok(())
}

fn digest<T: serde::Serialize>(domain: &str, value: &T) -> Result<String, PreparationError> {
    CanonicalDigestV1::digest(domain, value)
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| PreparationError::new("preparation.digest_failed", error.to_string()))
}
fn preparation_lease_error(error: crate::llm_contracts::GlobalRunLeaseError) -> PreparationError {
    PreparationError::new(
        "preparation.lease_transition_failed",
        format!("{}: {error}", error.code()),
    )
}
fn preparation_not_found() -> PreparationError {
    PreparationError::new(
        "preparation.not_found",
        "active run preparation was not found",
    )
}
fn token_expired() -> PreparationError {
    PreparationError::new("preparation.token_expired", "preparation token expired")
}
fn time_overflow() -> PreparationError {
    PreparationError::new(
        "preparation.time_overflow",
        "preparation expiration overflowed",
    )
}
fn close_mismatch() -> PreparationError {
    PreparationError::new(
        "preparation.close_receipt_mismatch",
        "prepared-session close receipt does not match the cleanup envelope",
    )
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
