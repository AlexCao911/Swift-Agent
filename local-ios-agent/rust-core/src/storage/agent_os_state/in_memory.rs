use std::collections::HashMap;

use serde::Serialize;

use crate::canonical_digest::CanonicalDigestV1;
use crate::llm_contracts::{
    GlobalRunLease, GlobalRunLeaseError, GlobalRunLeaseState, HostBindingCommit,
    HostBindingCrossLink, HostBindingError, HostBindingKind, HostBindingOperation,
    HostBindingOperationState, LLMBindingSchema, PackageBindingPreparation,
    ProfilePublishPreparation,
};

use super::{AgentOSStateRepository, GlobalRunLeaseRepository};

#[derive(Default)]
pub struct InMemoryAgentOSStateStore {
    operations: HashMap<String, HostBindingOperation>,
    idempotency: HashMap<(HostBindingKindKey, String), String>,
    cross_links: HashMap<String, HostBindingCrossLink>,
    global_run_lease: Option<GlobalRunLease>,
    last_lease_generation: u64,
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

    fn prepare<T: Serialize>(
        &mut self,
        key_kind: HostBindingKindKey,
        kind: HostBindingKind,
        idempotency_key: &str,
        subject_id: &str,
        profile_id: &str,
        profile_revision: u64,
        slot_id: &str,
        requirements_hash: &str,
        request: &T,
    ) -> Result<HostBindingOperation, HostBindingError> {
        let token = saga_token(kind, request)?;
        let token_digest = saga_token_digest(&token)?;
        let index = (key_kind, idempotency_key.to_string());
        if let Some(existing_token) = self.idempotency.get(&index) {
            let existing = self
                .operations
                .get(existing_token)
                .expect("idempotency index must reference operation");
            if existing.token() == token {
                return Ok(existing.clone());
            }
            return Err(conflict());
        }
        let operation = HostBindingOperation::new(
            kind,
            idempotency_key.to_string(),
            token.clone(),
            token_digest,
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
            &request,
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
            &request,
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

pub(super) fn saga_token<T: Serialize>(
    kind: HostBindingKind,
    request: &T,
) -> Result<String, HostBindingError> {
    #[derive(Serialize)]
    struct TokenDocument<'a, T> {
        kind: &'a str,
        request: &'a T,
    }
    let document = TokenDocument {
        kind: kind.as_str(),
        request,
    };
    CanonicalDigestV1::digest("saga-token:v1", &document)
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| {
            HostBindingError::new("host_binding.token_digest_failed", error.to_string())
        })
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
