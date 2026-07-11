use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostBindingKind {
    ProfilePublish,
    PackageBinding,
}

impl HostBindingKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ProfilePublish => "profile_publish",
            Self::PackageBinding => "package_binding",
        }
    }

    pub fn from_str(value: &str) -> Result<Self, HostBindingError> {
        match value {
            "profile_publish" => Ok(Self::ProfilePublish),
            "package_binding" => Ok(Self::PackageBinding),
            _ => Err(HostBindingError::new(
                "host_binding.invalid_persisted_state",
                format!("unknown host-binding kind: {value}"),
            )),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostBindingOperationState {
    Pending,
    HostUnbound,
}

impl HostBindingOperationState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::HostUnbound => "host_unbound",
        }
    }

    pub fn from_str(value: &str) -> Result<Self, HostBindingError> {
        match value {
            "pending" => Ok(Self::Pending),
            "host_unbound" => Ok(Self::HostUnbound),
            _ => Err(HostBindingError::new(
                "host_binding.invalid_persisted_state",
                format!("unknown host-binding operation state: {value}"),
            )),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProfilePublishPreparation {
    idempotency_key: String,
    agent_profile_id: String,
    agent_profile_revision: u64,
    llm_slot_id: String,
    requirements_hash: String,
}

impl ProfilePublishPreparation {
    pub fn new(
        idempotency_key: impl Into<String>,
        agent_profile_id: impl Into<String>,
        agent_profile_revision: u64,
        llm_slot_id: impl Into<String>,
        requirements_hash: impl Into<String>,
    ) -> Self {
        Self {
            idempotency_key: idempotency_key.into(),
            agent_profile_id: agent_profile_id.into(),
            agent_profile_revision,
            llm_slot_id: llm_slot_id.into(),
            requirements_hash: requirements_hash.into(),
        }
    }

    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn agent_profile_id(&self) -> &str {
        &self.agent_profile_id
    }
    pub fn agent_profile_revision(&self) -> u64 {
        self.agent_profile_revision
    }
    pub fn llm_slot_id(&self) -> &str {
        &self.llm_slot_id
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PackageBindingPreparation {
    idempotency_key: String,
    installation_id: String,
    agent_profile_id: String,
    agent_profile_revision: u64,
    llm_slot_id: String,
    requirements_hash: String,
}

impl PackageBindingPreparation {
    pub fn new(
        idempotency_key: impl Into<String>,
        installation_id: impl Into<String>,
        agent_profile_id: impl Into<String>,
        agent_profile_revision: u64,
        llm_slot_id: impl Into<String>,
        requirements_hash: impl Into<String>,
    ) -> Self {
        Self {
            idempotency_key: idempotency_key.into(),
            installation_id: installation_id.into(),
            agent_profile_id: agent_profile_id.into(),
            agent_profile_revision,
            llm_slot_id: llm_slot_id.into(),
            requirements_hash: requirements_hash.into(),
        }
    }

    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn installation_id(&self) -> &str {
        &self.installation_id
    }
    pub fn agent_profile_id(&self) -> &str {
        &self.agent_profile_id
    }
    pub fn agent_profile_revision(&self) -> u64 {
        self.agent_profile_revision
    }
    pub fn llm_slot_id(&self) -> &str {
        &self.llm_slot_id
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostBindingOperation {
    kind: HostBindingKind,
    idempotency_key: String,
    token: String,
    token_digest: String,
    subject_id: String,
    agent_profile_id: String,
    agent_profile_revision: u64,
    llm_slot_id: String,
    requirements_hash: String,
    state: HostBindingOperationState,
}

impl HostBindingOperation {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        kind: HostBindingKind,
        idempotency_key: String,
        token: String,
        token_digest: String,
        subject_id: String,
        agent_profile_id: String,
        agent_profile_revision: u64,
        llm_slot_id: String,
        requirements_hash: String,
        state: HostBindingOperationState,
    ) -> Self {
        Self {
            kind,
            idempotency_key,
            token,
            token_digest,
            subject_id,
            agent_profile_id,
            agent_profile_revision,
            llm_slot_id,
            requirements_hash,
            state,
        }
    }

    pub fn kind(&self) -> HostBindingKind {
        self.kind
    }
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn token(&self) -> &str {
        &self.token
    }
    pub fn token_digest(&self) -> &str {
        &self.token_digest
    }
    pub fn subject_id(&self) -> &str {
        &self.subject_id
    }
    pub fn agent_profile_id(&self) -> &str {
        &self.agent_profile_id
    }
    pub fn agent_profile_revision(&self) -> u64 {
        self.agent_profile_revision
    }
    pub fn llm_slot_id(&self) -> &str {
        &self.llm_slot_id
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
    pub fn state(&self) -> HostBindingOperationState {
        self.state
    }
    pub(crate) fn set_state(&mut self, state: HostBindingOperationState) {
        self.state = state;
    }
    pub(crate) fn with_token(mut self, token: String) -> Self {
        self.token = token;
        self
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostBindingTuple {
    binding_id: String,
    binding_revision: u64,
    binding_hash: String,
}

impl HostBindingTuple {
    pub fn new(
        binding_id: impl Into<String>,
        binding_revision: u64,
        binding_hash: impl Into<String>,
    ) -> Self {
        Self {
            binding_id: binding_id.into(),
            binding_revision,
            binding_hash: binding_hash.into(),
        }
    }
    pub fn binding_id(&self) -> &str {
        &self.binding_id
    }
    pub fn binding_revision(&self) -> u64 {
        self.binding_revision
    }
    pub fn binding_hash(&self) -> &str {
        &self.binding_hash
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostBindingStagingReceipt {
    token_digest: String,
    llm_slot_id: String,
    requirements_hash: String,
    binding: HostBindingTuple,
    receipt_digest: String,
}

impl HostBindingStagingReceipt {
    pub fn new(
        token_digest: impl Into<String>,
        llm_slot_id: impl Into<String>,
        requirements_hash: impl Into<String>,
        binding: HostBindingTuple,
        receipt_digest: impl Into<String>,
    ) -> Self {
        Self {
            token_digest: token_digest.into(),
            llm_slot_id: llm_slot_id.into(),
            requirements_hash: requirements_hash.into(),
            binding,
            receipt_digest: receipt_digest.into(),
        }
    }
    pub fn token_digest(&self) -> &str {
        &self.token_digest
    }
    pub fn llm_slot_id(&self) -> &str {
        &self.llm_slot_id
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
    pub fn binding(&self) -> &HostBindingTuple {
        &self.binding
    }
    pub fn receipt_digest(&self) -> &str {
        &self.receipt_digest
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostBindingCommit {
    token: String,
    binding: HostBindingTuple,
    receipt: HostBindingStagingReceipt,
}

impl HostBindingCommit {
    pub fn new(
        token: impl Into<String>,
        binding: HostBindingTuple,
        receipt: HostBindingStagingReceipt,
    ) -> Self {
        Self {
            token: token.into(),
            binding,
            receipt,
        }
    }
    pub fn token(&self) -> &str {
        &self.token
    }
    pub fn binding(&self) -> &HostBindingTuple {
        &self.binding
    }
    pub fn receipt(&self) -> &HostBindingStagingReceipt {
        &self.receipt
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostBindingCrossLink {
    operation_token: String,
    token_digest: String,
    kind: HostBindingKind,
    llm_slot_id: String,
    requirements_hash: String,
    binding: HostBindingTuple,
    staging_receipt_digest: String,
    state: HostBindingOperationState,
}

impl HostBindingCrossLink {
    pub(crate) fn new(operation: &HostBindingOperation, commit: &HostBindingCommit) -> Self {
        Self {
            operation_token: operation.token_digest.clone(),
            token_digest: operation.token_digest.clone(),
            kind: operation.kind,
            llm_slot_id: operation.llm_slot_id.clone(),
            requirements_hash: operation.requirements_hash.clone(),
            binding: commit.binding.clone(),
            staging_receipt_digest: commit.receipt.receipt_digest.clone(),
            state: HostBindingOperationState::HostUnbound,
        }
    }
    pub fn operation_token(&self) -> &str {
        &self.operation_token
    }
    pub fn token_digest(&self) -> &str {
        &self.token_digest
    }
    pub fn kind(&self) -> HostBindingKind {
        self.kind
    }
    pub fn llm_slot_id(&self) -> &str {
        &self.llm_slot_id
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
    pub fn binding(&self) -> &HostBindingTuple {
        &self.binding
    }
    pub fn staging_receipt_digest(&self) -> &str {
        &self.staging_receipt_digest
    }
    pub fn state(&self) -> HostBindingOperationState {
        self.state
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostBindingError {
    code: &'static str,
    message: String,
}

impl HostBindingError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub fn code(&self) -> &str {
        self.code
    }
}

impl fmt::Display for HostBindingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}
impl std::error::Error for HostBindingError {}
