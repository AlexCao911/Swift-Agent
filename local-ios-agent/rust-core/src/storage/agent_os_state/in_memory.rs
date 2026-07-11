use std::collections::HashMap;

use crate::canonical_digest::CanonicalDigestV1;
use crate::llm_contracts::{
    BearerTokenIssuer, GlobalRunLease, GlobalRunLeaseError, GlobalRunLeaseState, HostBindingCommit,
    HostBindingCrossLink, HostBindingError, HostBindingKind, HostBindingOperation,
    HostBindingOperationState, LLMBindingSchema, PackageBindingPreparation, PreparationError,
    PreparedSessionCleanupAcknowledgement, ProfilePublishPreparation, RunPreparationRecord,
    RunPreparationState,
};

use super::{AgentOSStateRepository, GlobalRunLeaseRepository, RunPreparationRepository};

#[derive(Default)]
pub struct InMemoryAgentOSStateStore {
    operations: HashMap<String, HostBindingOperation>,
    idempotency: HashMap<(HostBindingKindKey, String), String>,
    cross_links: HashMap<String, HostBindingCrossLink>,
    global_run_lease: Option<GlobalRunLease>,
    last_lease_generation: u64,
    run_preparations: HashMap<String, RunPreparationRecord>,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
enum HostBindingKindKey {
    Profile,
    Package,
}

impl InMemoryAgentOSStateStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn prepare(
        &mut self,
        key_kind: HostBindingKindKey,
        kind: HostBindingKind,
        idempotency_key: &str,
        subject_id: &str,
        profile_id: &str,
        profile_revision: u64,
        slot_id: &str,
        requirements_hash: &str,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let index = (key_kind, idempotency_key.to_string());
        if let Some(existing_token) = self.idempotency.get(&index) {
            let existing = self
                .operations
                .get(existing_token)
                .expect("idempotency index must reference operation");
            if existing.kind() == kind
                && existing.subject_id() == subject_id
                && existing.agent_profile_id() == profile_id
                && existing.agent_profile_revision() == profile_revision
                && existing.llm_slot_id() == slot_id
                && existing.requirements_hash() == requirements_hash
            {
                return Ok(existing.clone());
            }
            return Err(conflict());
        }
        let issued = BearerTokenIssuer::system()
            .issue("saga-token:v1")
            .map_err(|error| {
                HostBindingError::new("host_binding.token_failed", error.to_string())
            })?;
        let (token, authority) = issued.into_parts();
        let operation = HostBindingOperation::new(
            kind,
            idempotency_key.to_string(),
            token.clone(),
            authority.token_digest().to_string(),
            subject_id.to_string(),
            profile_id.to_string(),
            profile_revision,
            slot_id.to_string(),
            requirements_hash.to_string(),
            HostBindingOperationState::Pending,
        );
        self.idempotency.insert(index, token.clone());
        self.operations.insert(token, operation.clone());
        Ok(operation)
    }

    fn commit(
        &mut self,
        expected_kind: HostBindingKind,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let operation = self
            .operations
            .get(request.token())
            .ok_or_else(not_found)?
            .clone();
        validate_commit(expected_kind, &operation, &request)?;
        let expected = HostBindingCrossLink::new(&operation, &request);
        if let Some(existing) = self.cross_links.get(request.token()) {
            return if existing == &expected {
                Ok(existing.clone())
            } else {
                Err(conflict())
            };
        }
        self.cross_links
            .insert(request.token().to_string(), expected.clone());
        self.operations
            .get_mut(request.token())
            .unwrap()
            .set_state(HostBindingOperationState::HostUnbound);
        Ok(expected)
    }
}

impl AgentOSStateRepository for InMemoryAgentOSStateStore {
    fn prepare_profile_publish(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        self.prepare(
            HostBindingKindKey::Profile,
            HostBindingKind::ProfilePublish,
            request.idempotency_key(),
            request.agent_profile_id(),
            request.agent_profile_id(),
            request.agent_profile_revision(),
            request.llm_slot_id(),
            request.requirements_hash(),
        )
    }
    fn commit_profile_publish(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.commit(HostBindingKind::ProfilePublish, request)
    }
    fn begin_package_binding(
        &mut self,
        request: PackageBindingPreparation,
    ) -> Result<HostBindingOperation, HostBindingError> {
        self.prepare(
            HostBindingKindKey::Package,
            HostBindingKind::PackageBinding,
            request.idempotency_key(),
            request.installation_id(),
            request.agent_profile_id(),
            request.agent_profile_revision(),
            request.llm_slot_id(),
            request.requirements_hash(),
        )
    }
    fn attach_host_binding(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        self.commit(HostBindingKind::PackageBinding, request)
    }
    fn cross_link(&self, token: &str) -> Result<Option<HostBindingCrossLink>, HostBindingError> {
        Ok(self.cross_links.get(token).cloned())
    }
    fn matching_cross_link(
        &self,
        agent_profile_id: &str,
        agent_profile_revision: u64,
        llm_slot_id: &str,
        requirements_hash: &str,
        binding_id: &str,
        binding_revision: u64,
        binding_hash: &str,
    ) -> Result<Option<HostBindingCrossLink>, HostBindingError> {
        Ok(self
            .cross_links
            .values()
            .find(|link| {
                link.agent_profile_id() == agent_profile_id
                    && link.agent_profile_revision() == agent_profile_revision
                    && link.llm_slot_id() == llm_slot_id
                    && link.requirements_hash() == requirements_hash
                    && link.binding().binding_id() == binding_id
                    && link.binding().binding_revision() == binding_revision
                    && link.binding().binding_hash() == binding_hash
            })
            .cloned())
    }
    fn activate_matching_cross_link(
        &mut self,
        confirmation: &crate::llm_contracts::HostBindingActivationConfirmation,
    ) -> Result<HostBindingCrossLink, HostBindingError> {
        let (key, existing) = self
            .cross_links
            .iter()
            .find(|(_, link)| {
                link.agent_profile_id() == confirmation.agent_profile_id()
                    && link.agent_profile_revision() == confirmation.agent_profile_revision()
                    && link.llm_slot_id() == confirmation.llm_slot_id()
                    && link.requirements_hash() == confirmation.requirements_hash()
                    && link.binding() == confirmation.binding()
                    && link.staging_receipt_digest() == confirmation.staging_receipt_digest()
            })
            .map(|(key, link)| (key.clone(), link.clone()))
            .ok_or_else(|| {
                HostBindingError::new(
                    "host_binding.activation_mismatch",
                    "activation confirmation does not match an exact host-unbound cross-link",
                )
            })?;
        if existing.state() == HostBindingOperationState::Active {
            return Ok(existing);
        }
        if existing.state() != HostBindingOperationState::HostUnbound {
            return Err(HostBindingError::new(
                "host_binding.activation_state_stale",
                "host binding is not awaiting activation",
            ));
        }
        let active = existing.with_state(HostBindingOperationState::Active);
        self.cross_links.insert(key, active.clone());
        Ok(active)
    }
}

impl GlobalRunLeaseRepository for InMemoryAgentOSStateStore {
    fn acquire_legacy(
        &mut self,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.acquire(
            Some(run_id.to_string()),
            None,
            LLMBindingSchema::LegacyV1,
            host_epoch,
            GlobalRunLeaseState::Active,
            None,
        )
    }

    fn acquire_preparation(
        &mut self,
        preparation_id: &str,
        host_epoch: &str,
        expiration: u64,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        self.acquire(
            None,
            Some(preparation_id.to_string()),
            LLMBindingSchema::HostSlotV2,
            host_epoch,
            GlobalRunLeaseState::Preparing,
            Some(expiration),
        )
    }

    fn promote_preparation(
        &mut self,
        generation: u64,
        preparation_id: &str,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        let lease = self.exact_lease(generation, host_epoch)?;
        if lease.state() != GlobalRunLeaseState::Preparing
            || lease.preparation_id() != Some(preparation_id)
        {
            return Err(stale());
        }
        let promoted = lease.promoted(run_id.to_string());
        self.global_run_lease = Some(promoted.clone());
        Ok(promoted)
    }

    fn begin_release(
        &mut self,
        generation: u64,
        owner_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        let lease = self.exact_lease(generation, host_epoch)?;
        if !lease.owner_matches(owner_id) {
            return Err(stale());
        }
        if lease.state() == GlobalRunLeaseState::Releasing {
            return Ok(lease);
        }
        let releasing = lease.releasing();
        self.global_run_lease = Some(releasing.clone());
        Ok(releasing)
    }

    fn complete_release(
        &mut self,
        generation: u64,
        host_epoch: &str,
    ) -> Result<(), GlobalRunLeaseError> {
        let lease = self.exact_lease(generation, host_epoch)?;
        if lease.state() != GlobalRunLeaseState::Releasing {
            return Err(stale());
        }
        self.global_run_lease = None;
        Ok(())
    }

    fn recover_old_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
        let Some(lease) = self.global_run_lease.clone() else {
            return Ok(None);
        };
        if lease.host_process_epoch() == current_host_epoch {
            return Ok(None);
        }
        self.global_run_lease = None;
        Ok(Some(lease))
    }

    fn current_global_run_lease(&self) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError> {
        Ok(self.global_run_lease.clone())
    }
}

impl RunPreparationRepository for InMemoryAgentOSStateStore {
    fn create_preparation_and_acquire_lease(
        &mut self,
        mut record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        if self.global_run_lease.is_some() {
            return Err(PreparationError::new(
                "execution.global_run_busy",
                "another run or preparation owns the global run lease",
            ));
        }
        if self.run_preparations.values().any(|existing| {
            existing.preview().preparation_id() == record.preview().preparation_id()
                || existing.idempotency_key() == record.idempotency_key()
        }) {
            return Err(preparation_conflict());
        }
        let lease = self
            .acquire_preparation(
                record.preview().preparation_id(),
                record.preview().host_process_epoch(),
                record.preview().expiration_millis(),
            )
            .map_err(preparation_lease_error)?;
        record.set_lease_generation(lease.generation());
        self.run_preparations.insert(
            record.preview().preparation_id().to_string(),
            record.clone(),
        );
        Ok(record)
    }

    fn create_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        if let Some(existing) = self.run_preparations.get(record.preview().preparation_id()) {
            return if existing == &record {
                Ok(existing.clone())
            } else {
                Err(preparation_conflict())
            };
        }
        if self
            .run_preparations
            .values()
            .any(|existing| existing.idempotency_key() == record.idempotency_key())
        {
            return Err(preparation_conflict());
        }
        self.run_preparations.insert(
            record.preview().preparation_id().to_string(),
            record.clone(),
        );
        Ok(record)
    }

    fn save_run_preparation(
        &mut self,
        expected_state: RunPreparationState,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let existing = self
            .run_preparations
            .get(record.preview().preparation_id())
            .ok_or_else(preparation_not_found)?;
        if existing.state() != expected_state {
            return Err(preparation_stale());
        }
        self.run_preparations.insert(
            record.preview().preparation_id().to_string(),
            record.clone(),
        );
        Ok(record)
    }

    fn renew_preparation_and_lease(
        &mut self,
        expected_state: RunPreparationState,
        expected_token_generation: u64,
        expected_token_digest: &str,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let existing = self
            .run_preparations
            .get(record.preview().preparation_id())
            .ok_or_else(preparation_not_found)?;
        if existing.state() != expected_state
            || existing.preview().token_generation() != expected_token_generation
            || existing.preview().token_digest() != expected_token_digest
        {
            return Err(preparation_stale());
        }
        let lease = self
            .global_run_lease
            .clone()
            .ok_or_else(preparation_stale)?;
        if lease.state() != GlobalRunLeaseState::Preparing
            || lease.preparation_id() != Some(record.preview().preparation_id())
            || lease.generation() != record.preview().lease_generation()
            || lease.host_process_epoch() != record.preview().host_process_epoch()
        {
            return Err(preparation_stale());
        }
        self.global_run_lease = Some(lease.renewed(record.preview().expiration_millis()));
        self.run_preparations.insert(
            record.preview().preparation_id().to_string(),
            record.clone(),
        );
        Ok(record)
    }

    fn recover_preparations_for_new_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Vec<String>, PreparationError> {
        let mut recovered = Vec::new();
        for record in self.run_preparations.values_mut().filter(|record| {
            record.state() != RunPreparationState::Closed
                && record.preview().host_process_epoch() != current_host_epoch
        }) {
            record.close_for_epoch_end();
            recovered.push(record.preview().preparation_id().to_string());
        }
        if self
            .global_run_lease
            .as_ref()
            .is_some_and(|lease| lease.host_process_epoch() != current_host_epoch)
        {
            self.global_run_lease = None;
        }
        recovered.sort();
        Ok(recovered)
    }

    fn abort_run_preparation(
        &mut self,
        record: RunPreparationRecord,
        has_registered_session: bool,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let preview = record.preview();
        self.begin_release(
            preview.lease_generation(),
            preview.preparation_id(),
            preview.host_process_epoch(),
        )
        .map_err(preparation_lease_error)?;
        if !has_registered_session {
            self.complete_release(preview.lease_generation(), preview.host_process_epoch())
                .map_err(preparation_lease_error)?;
        }
        self.run_preparations
            .insert(preview.preparation_id().to_string(), record.clone());
        Ok(record)
    }

    fn acknowledge_prepared_cleanup(
        &mut self,
        record: RunPreparationRecord,
        acknowledgement: &PreparedSessionCleanupAcknowledgement,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let existing = self
            .run_preparations
            .get(record.preview().preparation_id())
            .ok_or_else(preparation_not_found)?;
        if existing.state() != RunPreparationState::Aborting {
            return Err(preparation_stale());
        }
        if let Some(current) = existing.cleanup_acknowledgement() {
            return if current == acknowledgement {
                Ok(existing.clone())
            } else {
                Err(preparation_stale())
            };
        }
        self.run_preparations.insert(
            record.preview().preparation_id().to_string(),
            record.clone(),
        );
        Ok(record)
    }

    fn close_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError> {
        let preview = record.preview();
        if record.cleanup_acknowledgement().is_none() {
            return Err(preparation_stale());
        }
        self.complete_release(preview.lease_generation(), preview.host_process_epoch())
            .map_err(preparation_lease_error)?;
        self.run_preparations
            .insert(preview.preparation_id().to_string(), record.clone());
        Ok(record)
    }

    fn run_preparation(
        &self,
        preparation_id: &str,
    ) -> Result<Option<RunPreparationRecord>, PreparationError> {
        Ok(self.run_preparations.get(preparation_id).cloned())
    }

    fn active_run_preparation(&self) -> Result<Option<RunPreparationRecord>, PreparationError> {
        let Some(lease) = &self.global_run_lease else {
            return Ok(None);
        };
        Ok(lease
            .preparation_id()
            .and_then(|id| self.run_preparations.get(id))
            .cloned())
    }

    fn list_run_preparations(&self) -> Result<Vec<RunPreparationRecord>, PreparationError> {
        Ok(self.run_preparations.values().cloned().collect())
    }
}

fn preparation_lease_error(error: GlobalRunLeaseError) -> PreparationError {
    PreparationError::new(
        "preparation.lease_transition_failed",
        format!("{}: {error}", error.code()),
    )
}
fn preparation_conflict() -> PreparationError {
    PreparationError::new(
        "preparation.idempotency_conflict",
        "preparation identity was replayed with different input",
    )
}
fn preparation_stale() -> PreparationError {
    PreparationError::new(
        "preparation.state_stale",
        "preparation state changed before persistence",
    )
}
fn preparation_not_found() -> PreparationError {
    PreparationError::new("preparation.not_found", "run preparation was not found")
}

impl InMemoryAgentOSStateStore {
    fn acquire(
        &mut self,
        run_id: Option<String>,
        preparation_id: Option<String>,
        schema: LLMBindingSchema,
        host_epoch: &str,
        state: GlobalRunLeaseState,
        expiration: Option<u64>,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        if self.global_run_lease.is_some() {
            return Err(busy());
        }
        self.last_lease_generation =
            self.last_lease_generation.checked_add(1).ok_or_else(|| {
                GlobalRunLeaseError::new(
                    "execution.global_run_lease_generation_exhausted",
                    "global run lease generation exhausted",
                )
            })?;
        let lease = GlobalRunLease::new(
            self.last_lease_generation,
            run_id,
            preparation_id,
            schema,
            host_epoch.to_string(),
            state,
            expiration,
        );
        self.global_run_lease = Some(lease.clone());
        Ok(lease)
    }

    fn exact_lease(
        &self,
        generation: u64,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError> {
        let lease = self.global_run_lease.clone().ok_or_else(stale)?;
        if lease.generation() != generation || lease.host_process_epoch() != host_epoch {
            return Err(stale());
        }
        Ok(lease)
    }
}

pub(super) fn busy() -> GlobalRunLeaseError {
    GlobalRunLeaseError::new(
        "execution.global_run_busy",
        "another agent run owns the global run lease",
    )
}

pub(super) fn stale() -> GlobalRunLeaseError {
    GlobalRunLeaseError::new(
        "execution.global_run_lease_stale",
        "global run lease generation, owner, epoch, or state is stale",
    )
}

pub(super) fn saga_token_digest(token: &str) -> Result<String, HostBindingError> {
    CanonicalDigestV1::digest("saga-token:v1", &token)
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| {
            HostBindingError::new("host_binding.token_digest_failed", error.to_string())
        })
}

pub(super) fn validate_commit(
    expected_kind: HostBindingKind,
    operation: &HostBindingOperation,
    request: &HostBindingCommit,
) -> Result<(), HostBindingError> {
    if operation.kind() != expected_kind {
        return Err(HostBindingError::new(
            "host_binding.operation_kind_mismatch",
            "operation kind does not match commit endpoint",
        ));
    }
    let receipt = request.receipt();
    if receipt.binding() != request.binding() {
        return Err(HostBindingError::new(
            "host_binding.binding_mismatch",
            "staging receipt binding tuple differs from commit tuple",
        ));
    }
    if receipt.token_digest() != operation.token_digest() {
        return Err(HostBindingError::new(
            "host_binding.token_mismatch",
            "staging receipt token digest differs from operation",
        ));
    }
    if receipt.llm_slot_id() != operation.llm_slot_id()
        || receipt.requirements_hash() != operation.requirements_hash()
    {
        return Err(HostBindingError::new(
            "host_binding.requirements_mismatch",
            "staging receipt slot or requirements differs from operation",
        ));
    }
    Ok(())
}

pub(super) fn conflict() -> HostBindingError {
    HostBindingError::new(
        "host_binding.idempotency_conflict",
        "idempotency key was replayed with different input",
    )
}
pub(super) fn not_found() -> HostBindingError {
    HostBindingError::new(
        "host_binding.operation_not_found",
        "host-binding operation was not found",
    )
}
