use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use crate::canonical_digest::CanonicalDigestV1;
use crate::conversation::ConversationRunFrame;
use crate::llm_contracts::{
    HostAttestation, HostCommandEnvelope, HostExecutionPhase, HostRunHandle, HostSessionRecord,
    HostWorkerRecord, PreparationAbortReason, PreparationError, PreparationReconciliation,
    PreparedSessionCleanupAcknowledgement, PreparedSessionCleanupEnvelope,
    PreparedSessionClosedReceipt, PreparedSessionRegistration, PreparedStartValidator,
    RenewalReplay, RunPreparationPreview, RunPreparationRecord, RunPreparationRequest,
    RunPreparationState,
};
use crate::run_snapshot::{
    derive_authoritative_preparation, FrozenGenerationTurn, OpaqueHostBindingCrossLink,
    ResolvedRunSnapshot, RunSnapshotRepository, RunSnapshotResolver, RunSnapshotSourceCatalog,
    StartRunRequest,
};
use crate::storage::agent_os_state::SharedAgentOSStateStore;
use crate::storage::{
    InMemoryTransactionRunner, PreparedHostRunCommit, StorageError, TransactionRunner,
    UnifiedRuntimeStateRepository,
};
use crate::user_customization::{ComponentCatalogService, InMemoryAgentProfileRepository};

pub type RunSnapshotResult<T> = Result<T, RunSnapshotError>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotError {
    code: String,
    message: String,
}

pub struct RunSnapshotService {
    resolver: RunSnapshotResolver,
}

#[derive(Clone)]
pub struct RunPreparationService {
    state_store: SharedAgentOSStateStore,
    host_process_epoch: String,
    snapshot_service: Option<Arc<RunSnapshotService>>,
    frozen_inputs: Arc<Mutex<BTreeMap<String, FrozenGenerationTurn>>>,
    runtime_state: Option<Arc<dyn UnifiedRuntimeStateRepository>>,
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
        let _ = (repository, runner);
        Self { resolver }
    }

    pub fn from_real_repositories(
        profile_repository: InMemoryAgentProfileRepository,
        component_catalog: ComponentCatalogService,
        runner: Box<dyn TransactionRunner>,
    ) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::new(profile_repository, component_catalog),
            RunSnapshotRepository::default(),
            runner,
        )
    }

    pub fn from_unified_repositories(
        runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
        profile_repository: InMemoryAgentProfileRepository,
        component_catalog: ComponentCatalogService,
        runner: Box<dyn TransactionRunner>,
    ) -> Self {
        Self::new(
            RunSnapshotSourceCatalog::new_unified(
                runtime_state,
                profile_repository,
                component_catalog,
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

    pub fn fixture_with_host_slot_v2() -> Self {
        Self::new(
            RunSnapshotSourceCatalog::fixture_with_host_slot_v2(),
            RunSnapshotRepository::default(),
            Box::new(InMemoryTransactionRunner::default()),
        )
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
            snapshot_service: None,
            frozen_inputs: Arc::new(Mutex::new(BTreeMap::new())),
            runtime_state: None,
        }
    }

    pub fn with_authoritative_preview(
        state_store: SharedAgentOSStateStore,
        host_process_epoch: impl Into<String>,
        snapshot_service: Arc<RunSnapshotService>,
    ) -> Self {
        Self {
            state_store,
            host_process_epoch: host_process_epoch.into(),
            snapshot_service: Some(snapshot_service),
            frozen_inputs: Arc::new(Mutex::new(BTreeMap::new())),
            runtime_state: None,
        }
    }

    pub fn with_host_runtime(
        state_store: SharedAgentOSStateStore,
        host_process_epoch: impl Into<String>,
        snapshot_service: Arc<RunSnapshotService>,
        runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
    ) -> Self {
        Self {
            state_store,
            host_process_epoch: host_process_epoch.into(),
            snapshot_service: Some(snapshot_service),
            frozen_inputs: Arc::new(Mutex::new(BTreeMap::new())),
            runtime_state: Some(runtime_state),
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn preview_authoritative(
        &self,
        idempotency_key: impl Into<String>,
        preparation_id: impl Into<String>,
        proposed_run_id: impl Into<String>,
        start_request: StartRunRequest,
        frame: &ConversationRunFrame,
        now_millis: u64,
    ) -> Result<RunPreparationPreview, PreparationError> {
        let snapshot_service = self.snapshot_service.as_ref().ok_or_else(|| {
            PreparationError::new(
                "preparation.authoritative_preview_unavailable",
                "run preparation service was not configured with Rust snapshot authority",
            )
        })?;
        let sources = snapshot_service
            .resolver
            .resolve_host_slot_preparation(&start_request)
            .map_err(preparation_snapshot_error)?;
        let derived = derive_authoritative_preparation(&start_request, frame, &sources)
            .map_err(preparation_snapshot_error)?;
        let input_id = derived.binding.model_input_id().to_string();
        self.frozen_inputs
            .lock()
            .map_err(|_| preparation_vault_poisoned())?
            .insert(input_id.clone(), derived.frozen_turn.clone());
        let request = RunPreparationRequest::new(
            idempotency_key,
            preparation_id,
            proposed_run_id,
            derived.binding,
        );
        let frozen_initial_turn = crate::llm_contracts::FrozenInitialTurn::new(
            derived.frozen_turn.payload,
            derived.frozen_turn.disclosure,
        );
        match self.preview_derived(request, frozen_initial_turn, now_millis) {
            Ok(preview) => Ok(preview),
            Err(error) => {
                self.frozen_inputs
                    .lock()
                    .map_err(|_| preparation_vault_poisoned())?
                    .remove(&input_id);
                Err(error)
            }
        }
    }

    pub fn frozen_model_input(&self, input_id: &str) -> Result<Option<Vec<u8>>, PreparationError> {
        self.frozen_inputs
            .lock()
            .map(|inputs| {
                inputs
                    .get(input_id)
                    .map(|turn| turn.canonical_model_input.clone())
            })
            .map_err(|_| preparation_vault_poisoned())
    }

    fn frozen_turn(
        &self,
        input_id: &str,
    ) -> Result<Option<FrozenGenerationTurn>, PreparationError> {
        self.frozen_inputs
            .lock()
            .map(|inputs| inputs.get(input_id).cloned())
            .map_err(|_| preparation_vault_poisoned())
    }

    fn preview_derived(
        &self,
        request: RunPreparationRequest,
        frozen_initial_turn: crate::llm_contracts::FrozenInitialTurn,
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
            let preview = RunPreparationPreview::new(
                &request,
                token,
                token_digest,
                binding_digest,
                frozen_initial_turn,
                self.host_process_epoch.clone(),
                0,
                expiration,
                deadline,
            );
            let record =
                RunPreparationRecord::new(request.idempotency_key().to_string(), preview.clone());
            let persisted = store.create_preparation_and_acquire_lease(record)?;
            Ok(persisted.preview().clone())
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
            let presented_digest = preparation_token_digest(token)?;
            if !preparation_token_matches(token, record.preview().token_digest())? {
                if let Some(replay) = record.renewals().get(&presented_digest) {
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
            let expected_token_generation = record.preview().token_generation();
            let expected_token_digest = record.preview().token_digest().to_string();
            record.renewals_mut().insert(
                presented_digest,
                RenewalReplay::new(idempotency_key.to_string(), renewed.clone()),
            );
            *record.preview_mut() = renewed.clone();
            store.renew_preparation_and_lease(
                expected_state,
                expected_token_generation,
                &expected_token_digest,
                record,
            )?;
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
    ) -> Result<HostRunHandle, PreparationError> {
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
        let binding = record.preview().binding();
        let requirements = binding.requirements().ok_or_else(|| {
            PreparationError::new(
                "preparation.frozen_requirements_missing",
                "preparation does not contain Rust-frozen LLM requirements",
            )
        })?;
        let cross_link = self
            .state_store
            .with_host_binding(|store| {
                store.matching_cross_link(
                    binding.agent_profile_id(),
                    binding.agent_profile_revision(),
                    requirements.slot_id(),
                    binding.requirements_hash(),
                    registration.binding_id(),
                    registration.binding_revision(),
                    registration.binding_hash(),
                )
            })
            .map_err(|error| {
                PreparationError::new("preparation.host_binding_query_failed", error.to_string())
            })?;
        let frozen_input = self.frozen_model_input(binding.model_input_id())?;
        if let Err(error) = PreparedStartValidator::validate(
            &record,
            &attestation,
            cross_link.as_ref(),
            frozen_input.as_deref(),
            now_millis,
        ) {
            self.begin_abort_preparation(
                record.preview().preparation_id(),
                Some(token),
                &format!("commit-rejected:{}", record.preview().preparation_id()),
                PreparationAbortReason::CommitRejected,
            )?;
            return Err(error);
        }
        let Some(runtime_state) = self.runtime_state.as_ref() else {
            self.begin_abort_preparation(
                record.preview().preparation_id(),
                Some(token),
                &format!(
                    "host-runtime-unavailable:{}",
                    record.preview().preparation_id()
                ),
                PreparationAbortReason::PreparationFailed,
            )?;
            return Err(PreparationError::new(
                "execution.host_runtime_unavailable",
                "host-backed LLM execution requires the unified runtime aggregate",
            ));
        };
        let frozen_turn = self.frozen_turn(binding.model_input_id())?.ok_or_else(|| {
            PreparationError::new(
                "preparation.frozen_turn_missing",
                "Rust-frozen generation turn is unavailable",
            )
        })?;
        let current_sources = self
            .snapshot_service
            .as_ref()
            .ok_or_else(|| {
                PreparationError::new(
                    "preparation.authoritative_preview_unavailable",
                    "host commit cannot revalidate authoritative snapshot sources",
                )
            })?
            .resolver
            .resolve_host_slot_preparation(&frozen_turn.start_request)
            .map_err(preparation_snapshot_error)?;
        if current_sources != frozen_turn.sources {
            self.begin_abort_preparation(
                record.preview().preparation_id(),
                Some(token),
                &format!("source-conflict:{}", record.preview().preparation_id()),
                PreparationAbortReason::CommitConflict,
            )?;
            return Err(PreparationError::new(
                "preparation.source_revision_conflict",
                "profile, component, tool schema, or requirement source changed after preview",
            ));
        }
        if frozen_turn.payload_digest
            != frozen_turn.payload.expected_digest().map_err(|error| {
                PreparationError::new("preparation.host_payload_invalid", error.to_string())
            })?
            || frozen_turn.disclosure_digest
                != frozen_turn.disclosure.expected_digest().map_err(|error| {
                    PreparationError::new("preparation.disclosure_invalid", error.to_string())
                })?
            || frozen_turn.disclosure_digest != binding.initial_disclosure_digest()
        {
            return Err(PreparationError::new(
                "preparation.frozen_turn_digest_mismatch",
                "frozen host payload or disclosure changed before commit",
            ));
        }
        let snapshot = ResolvedRunSnapshot::new_host_slot_v2(
            frozen_turn.start_request.clone(),
            frozen_turn.sources.profile_version,
            frozen_turn.sources.component_versions.clone(),
            frozen_turn.sources.requirements.clone(),
            binding.requirements_hash(),
            OpaqueHostBindingCrossLink::new(
                registration.binding_id(),
                registration.binding_revision(),
                registration.binding_hash(),
            ),
            frozen_turn.sources.tool_bindings.clone(),
            frozen_turn.sources.memory_binding.clone(),
            frozen_turn.sources.voice_binding.clone(),
            now_millis,
        );
        let snapshot_json = snapshot
            .host_v2_json(
                record.preview().proposed_run_id(),
                registration.swift_snapshot_id(),
                &attestation,
            )
            .map_err(|error| {
                PreparationError::new(
                    "preparation.snapshot_serialization_failed",
                    error.to_string(),
                )
            })?;
        let snapshot_value: serde_json::Value =
            serde_json::from_str(&snapshot_json).map_err(|error| {
                PreparationError::new(
                    "preparation.snapshot_serialization_failed",
                    error.to_string(),
                )
            })?;
        let snapshot_digest =
            CanonicalDigestV1::digest("resolved-run-snapshot:v1", &snapshot_value)
                .map_err(|error| {
                    PreparationError::new("preparation.snapshot_digest_failed", error.to_string())
                })?
                .as_str()
                .to_string();
        let command_id = crate::llm_contracts::BearerTokenIssuer::system()
            .issue("saga-token:v1")
            .map_err(|error| {
                PreparationError::new("preparation.command_id_failed", error.to_string())
            })?
            .raw()
            .to_string();
        let command = HostCommandEnvelope::start_generation(
            command_id.clone(),
            record.preview().proposed_run_id(),
            registration.session_handle(),
            &self.host_process_epoch,
            frozen_turn.payload,
            frozen_turn.disclosure,
        )
        .map_err(|error| {
            PreparationError::new("preparation.host_command_invalid", error.to_string())
        })?;
        let worker = HostWorkerRecord::new(
            record.preview().proposed_run_id(),
            registration.session_handle(),
            &self.host_process_epoch,
        )
        .with_execution_phase(Some(HostExecutionPhase::AwaitingStartCommandAck))
        .with_generation_request(
            command.payload.clone(),
            command.disclosure.clone().ok_or_else(|| {
                PreparationError::new(
                    "preparation.host_command_invalid",
                    "start command disclosure is missing",
                )
            })?,
        );
        let session = HostSessionRecord::new(
            record.preview().proposed_run_id(),
            registration.session_handle(),
            &self.host_process_epoch,
            registration.binding_id(),
            registration.binding_revision(),
            registration.binding_hash(),
        );
        runtime_state
            .commit_prepared_host_run(PreparedHostRunCommit {
                preparation_id: record.preview().preparation_id().to_string(),
                consumed_token_digest: record.preview().token_digest().to_string(),
                lease_generation: record.preview().lease_generation(),
                snapshot_digest,
                snapshot_json,
                initial_event_code: "run.started".into(),
                initial_event_payload: record.preview().binding_digest().to_string(),
                worker,
                session,
                first_command: command,
            })
            .map_err(runtime_state_error)?;
        self.frozen_inputs
            .lock()
            .map_err(|_| preparation_vault_poisoned())?
            .remove(binding.model_input_id());
        Ok(HostRunHandle::new(
            record.preview().proposed_run_id(),
            registration.session_handle(),
            command_id,
        ))
    }

    pub fn reconcile_preparation(
        &self,
        preparation_id: &str,
        proposed_run_id: &str,
        token_digest: &str,
    ) -> Result<PreparationReconciliation, PreparationError> {
        self.runtime_state
            .as_ref()
            .ok_or_else(|| {
                PreparationError::new(
                    "execution.host_runtime_unavailable",
                    "preparation reconciliation requires the unified runtime aggregate",
                )
            })?
            .reconcile_preparation(preparation_id, proposed_run_id, token_digest)
            .map_err(|error| {
                if error.code() == "preparation.reconciliation_identity_mismatch" {
                    PreparationError::new(
                        "preparation.reconciliation_identity_mismatch",
                        error.to_string(),
                    )
                } else {
                    runtime_state_error(error)
                }
            })
    }

    pub fn begin_abort_preparation(
        &self,
        preparation_id: &str,
        token: Option<&str>,
        idempotency_key: &str,
        reason: PreparationAbortReason,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let result = self.state_store.with_preparation_mut(|store| {
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
                && !token
                    .map(|token| preparation_token_matches(token, record.preview().token_digest()))
                    .transpose()?
                    .unwrap_or(false)
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
        });
        if result
            .as_ref()
            .is_err_and(|error| error.code() == "preparation.not_found")
        {
            if let (Some(runtime_state), Some(token)) = (&self.runtime_state, token) {
                let token_digest = preparation_token_digest(token)?;
                if runtime_state
                    .committed_run_handle(preparation_id, &token_digest)
                    .map_err(runtime_state_error)?
                    .is_some()
                {
                    return Err(PreparationError::new(
                        "preparation.already_committed",
                        "preparation already committed to an active host run",
                    ));
                }
            }
        }
        result
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
            if record.cleanup_acknowledgement().is_none() {
                return Err(PreparationError::new(
                    "preparation.cleanup_not_acknowledged",
                    "prepared-session cleanup command has not been acknowledged",
                ));
            }
            if !receipt.matches_cleanup(cleanup) {
                return Err(close_mismatch());
            }
            let expected_digest =
                prepared_close_receipt_digest(cleanup, receipt.close_disposition())?;
            if !constant_time_text_eq(receipt.receipt_digest(), &expected_digest) {
                return Err(close_mismatch());
            }
            record.close(receipt);
            store.close_run_preparation(record)
        })
    }

    pub fn ack_prepared_session_cleanup(
        &self,
        acknowledgement: PreparedSessionCleanupAcknowledgement,
    ) -> Result<RunPreparationRecord, PreparationError> {
        self.state_store.with_preparation_mut(|store| {
            let mut record = store
                .run_preparation(acknowledgement.preparation_id())?
                .ok_or_else(preparation_not_found)?;
            let cleanup = record.cleanup().ok_or_else(close_mismatch)?;
            if !acknowledgement.matches_cleanup(cleanup) {
                return Err(close_mismatch());
            }
            if let Some(existing) = record.cleanup_acknowledgement() {
                return if existing == &acknowledgement {
                    Ok(record)
                } else {
                    Err(close_mismatch())
                };
            }
            record.acknowledge_cleanup(acknowledgement.clone());
            store.acknowledge_prepared_cleanup(record, &acknowledgement)
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
        self.state_store.with_preparation_mut(|store| {
            store.recover_preparations_for_new_epoch(current_host_epoch)
        })
    }
}

fn validate_token(
    record: &RunPreparationRecord,
    token: &str,
    binding_digest: &str,
    host_epoch: &str,
    now_millis: u64,
) -> Result<(), PreparationError> {
    if !preparation_token_matches(token, record.preview().token_digest())? {
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
    let _ = (preparation_id, proposed_run_id, now_millis);
    crate::llm_contracts::BearerTokenIssuer::system()
        .issue_at_generation("preparation-token:v1", generation)
        .map(|issued| {
            let (raw, authority) = issued.into_parts();
            (raw, authority.token_digest().to_string())
        })
        .map_err(|error| {
            PreparationError::new("preparation.token_generation_failed", error.to_string())
        })
}

fn preparation_token_digest(token: &str) -> Result<String, PreparationError> {
    crate::llm_contracts::BearerTokenIssuer::system()
        .digest("preparation-token:v1", token)
        .map_err(|error| {
            PreparationError::new("preparation.token_digest_failed", error.to_string())
        })
}

fn preparation_token_matches(token: &str, digest: &str) -> Result<bool, PreparationError> {
    crate::llm_contracts::BearerTokenIssuer::system()
        .matches_digest("preparation-token:v1", token, digest)
        .map_err(|error| {
            PreparationError::new("preparation.token_digest_failed", error.to_string())
        })
}

fn make_cleanup(
    registration: &PreparedSessionRegistration,
    reason: PreparationAbortReason,
) -> Result<PreparedSessionCleanupEnvelope, PreparationError> {
    let command_id = crate::llm_contracts::BearerTokenIssuer::system()
        .issue("prepared-session-cleanup-command:v1")
        .map_err(|error| PreparationError::new("preparation.cleanup_id_failed", error.to_string()))?
        .raw()
        .to_string();
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

fn prepared_close_receipt_digest(
    cleanup: &PreparedSessionCleanupEnvelope,
    close_disposition: &str,
) -> Result<String, PreparationError> {
    #[derive(serde::Serialize)]
    struct Document<'a> {
        cleanup_command_id: &'a str,
        preparation_id: &'a str,
        proposed_run_id: &'a str,
        session_handle: &'a str,
        host_process_epoch: &'a str,
        cleanup_sequence: u64,
        prepared_session_registration_digest: &'a str,
        cleanup_command_digest: &'a str,
        close_disposition: &'a str,
    }
    digest(
        "prepared-session-closed-receipt:v1",
        &Document {
            cleanup_command_id: cleanup.cleanup_command_id(),
            preparation_id: cleanup.preparation_id(),
            proposed_run_id: cleanup.proposed_run_id(),
            session_handle: cleanup.session_handle(),
            host_process_epoch: cleanup.host_process_epoch(),
            cleanup_sequence: cleanup.preparation_cleanup_sequence(),
            prepared_session_registration_digest: cleanup.prepared_session_registration_digest(),
            cleanup_command_digest: cleanup.cleanup_command_digest(),
            close_disposition,
        },
    )
}

fn constant_time_text_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
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
fn preparation_not_found() -> PreparationError {
    PreparationError::new(
        "preparation.not_found",
        "active run preparation was not found",
    )
}
fn preparation_snapshot_error(error: RunSnapshotError) -> PreparationError {
    PreparationError::new(
        "preparation.authoritative_preview_failed",
        format!("{}: {error}", error.code()),
    )
}
fn preparation_vault_poisoned() -> PreparationError {
    PreparationError::new(
        "preparation.model_input_vault_poisoned",
        "prepared model input vault lock was poisoned",
    )
}
fn runtime_state_error(error: crate::storage::RuntimeStateError) -> PreparationError {
    PreparationError::new(
        "preparation.runtime_state_failed",
        format!("{}: {error}", error.code()),
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
