use std::collections::HashMap;

use serde::Serialize;

use crate::canonical_digest::CanonicalDigestV1;
use crate::llm_contracts::{
    HostBindingCommit, HostBindingCrossLink, HostBindingError, HostBindingKind,
    HostBindingOperation, HostBindingOperationState, PackageBindingPreparation,
    ProfilePublishPreparation,
};

use super::AgentOSStateRepository;

#[derive(Default)]
pub struct InMemoryAgentOSStateStore {
    operations: HashMap<String, HostBindingOperation>,
    idempotency: HashMap<(HostBindingKindKey, String), String>,
    cross_links: HashMap<String, HostBindingCrossLink>,
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
