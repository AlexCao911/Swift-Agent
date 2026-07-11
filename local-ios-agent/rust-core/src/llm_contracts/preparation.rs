use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RunPreparationState {
    Pending,
    Registered,
    Aborting,
    Closed,
}

impl RunPreparationState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Registered => "registered",
            Self::Aborting => "aborting",
            Self::Closed => "closed",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PreparationAbortReason {
    UserDenied,
    PreparationFailed,
    TokenExpired,
    CommitRejected,
    CommitConflict,
    HostShutdown,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparationBinding {
    agent_profile_id: String,
    agent_profile_revision: u64,
    conversation_frame_digest: String,
    execution_plan_digest: String,
    requirements_hash: String,
    tool_schema_digest: String,
    model_input_id: String,
    model_input_digest: String,
    source_revisions_digest: String,
    initial_disclosure_digest: String,
}

impl PreparationBinding {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        agent_profile_id: impl Into<String>,
        agent_profile_revision: u64,
        conversation_frame_digest: impl Into<String>,
        execution_plan_digest: impl Into<String>,
        requirements_hash: impl Into<String>,
        tool_schema_digest: impl Into<String>,
        model_input_id: impl Into<String>,
        model_input_digest: impl Into<String>,
        source_revisions_digest: impl Into<String>,
        initial_disclosure_digest: impl Into<String>,
    ) -> Self {
        Self {
            agent_profile_id: agent_profile_id.into(),
            agent_profile_revision,
            conversation_frame_digest: conversation_frame_digest.into(),
            execution_plan_digest: execution_plan_digest.into(),
            requirements_hash: requirements_hash.into(),
            tool_schema_digest: tool_schema_digest.into(),
            model_input_id: model_input_id.into(),
            model_input_digest: model_input_digest.into(),
            source_revisions_digest: source_revisions_digest.into(),
            initial_disclosure_digest: initial_disclosure_digest.into(),
        }
    }
    pub fn agent_profile_id(&self) -> &str {
        &self.agent_profile_id
    }
    pub fn agent_profile_revision(&self) -> u64 {
        self.agent_profile_revision
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
    pub fn model_input_id(&self) -> &str {
        &self.model_input_id
    }
    pub fn model_input_digest(&self) -> &str {
        &self.model_input_digest
    }
    pub fn source_revisions_digest(&self) -> &str {
        &self.source_revisions_digest
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RunPreparationRequest {
    idempotency_key: String,
    preparation_id: String,
    proposed_run_id: String,
    binding: PreparationBinding,
}

impl RunPreparationRequest {
    pub fn new(
        idempotency_key: impl Into<String>,
        preparation_id: impl Into<String>,
        proposed_run_id: impl Into<String>,
        binding: PreparationBinding,
    ) -> Self {
        Self {
            idempotency_key: idempotency_key.into(),
            preparation_id: preparation_id.into(),
            proposed_run_id: proposed_run_id.into(),
            binding,
        }
    }
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn proposed_run_id(&self) -> &str {
        &self.proposed_run_id
    }
    pub fn binding(&self) -> &PreparationBinding {
        &self.binding
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RunPreparationPreview {
    preparation_id: String,
    proposed_run_id: String,
    token: String,
    token_digest: String,
    token_generation: u64,
    binding: PreparationBinding,
    binding_digest: String,
    host_process_epoch: String,
    lease_generation: u64,
    expiration_millis: u64,
    total_deadline_millis: u64,
}

impl RunPreparationPreview {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        request: &RunPreparationRequest,
        token: String,
        token_digest: String,
        binding_digest: String,
        host_epoch: String,
        lease_generation: u64,
        expiration_millis: u64,
        total_deadline_millis: u64,
    ) -> Self {
        Self {
            preparation_id: request.preparation_id.clone(),
            proposed_run_id: request.proposed_run_id.clone(),
            token,
            token_digest,
            token_generation: 1,
            binding: request.binding.clone(),
            binding_digest,
            host_process_epoch: host_epoch,
            lease_generation,
            expiration_millis,
            total_deadline_millis,
        }
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn proposed_run_id(&self) -> &str {
        &self.proposed_run_id
    }
    pub fn token(&self) -> &str {
        &self.token
    }
    pub fn token_digest(&self) -> &str {
        &self.token_digest
    }
    pub fn token_generation(&self) -> u64 {
        self.token_generation
    }
    pub fn binding(&self) -> &PreparationBinding {
        &self.binding
    }
    pub fn binding_digest(&self) -> &str {
        &self.binding_digest
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn lease_generation(&self) -> u64 {
        self.lease_generation
    }
    pub fn expiration_millis(&self) -> u64 {
        self.expiration_millis
    }
    pub fn total_deadline_millis(&self) -> u64 {
        self.total_deadline_millis
    }

    pub(crate) fn renewed(&self, token: String, token_digest: String, expiration: u64) -> Self {
        let mut next = self.clone();
        next.token = token;
        next.token_digest = token_digest;
        next.token_generation += 1;
        next.expiration_millis = expiration;
        next
    }

    pub(crate) fn set_lease_generation(&mut self, generation: u64) {
        self.lease_generation = generation;
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedSessionRegistration {
    idempotency_key: String,
    preparation_id: String,
    proposed_run_id: String,
    session_handle: String,
    swift_snapshot_id: String,
    host_process_epoch: String,
    binding_hash: String,
    registration_digest: String,
}

impl PreparedSessionRegistration {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        idempotency_key: impl Into<String>,
        preparation_id: impl Into<String>,
        proposed_run_id: impl Into<String>,
        session_handle: impl Into<String>,
        swift_snapshot_id: impl Into<String>,
        host_process_epoch: impl Into<String>,
        binding_hash: impl Into<String>,
        registration_digest: impl Into<String>,
    ) -> Self {
        Self {
            idempotency_key: idempotency_key.into(),
            preparation_id: preparation_id.into(),
            proposed_run_id: proposed_run_id.into(),
            session_handle: session_handle.into(),
            swift_snapshot_id: swift_snapshot_id.into(),
            host_process_epoch: host_process_epoch.into(),
            binding_hash: binding_hash.into(),
            registration_digest: registration_digest.into(),
        }
    }
    pub fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn proposed_run_id(&self) -> &str {
        &self.proposed_run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn swift_snapshot_id(&self) -> &str {
        &self.swift_snapshot_id
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn binding_hash(&self) -> &str {
        &self.binding_hash
    }
    pub fn registration_digest(&self) -> &str {
        &self.registration_digest
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostAttestation {
    registration: PreparedSessionRegistration,
    preparation_binding_digest: String,
    egress_attestation_digest: String,
    expiration_millis: u64,
}

impl HostAttestation {
    pub fn from_registration(
        registration: PreparedSessionRegistration,
        preparation_binding_digest: impl Into<String>,
        egress_attestation_digest: impl Into<String>,
        expiration_millis: u64,
    ) -> Self {
        Self {
            registration,
            preparation_binding_digest: preparation_binding_digest.into(),
            egress_attestation_digest: egress_attestation_digest.into(),
            expiration_millis,
        }
    }
    pub fn registration(&self) -> &PreparedSessionRegistration {
        &self.registration
    }
    pub fn preparation_binding_digest(&self) -> &str {
        &self.preparation_binding_digest
    }
    pub fn expiration_millis(&self) -> u64 {
        self.expiration_millis
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedSessionCleanupEnvelope {
    cleanup_command_id: String,
    preparation_id: String,
    proposed_run_id: String,
    session_handle: String,
    host_process_epoch: String,
    preparation_cleanup_sequence: u64,
    reason: PreparationAbortReason,
    prepared_session_registration_digest: String,
    cleanup_command_digest: String,
}

impl PreparedSessionCleanupEnvelope {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        command_id: String,
        registration: &PreparedSessionRegistration,
        reason: PreparationAbortReason,
        digest: String,
    ) -> Self {
        Self {
            cleanup_command_id: command_id,
            preparation_id: registration.preparation_id.clone(),
            proposed_run_id: registration.proposed_run_id.clone(),
            session_handle: registration.session_handle.clone(),
            host_process_epoch: registration.host_process_epoch.clone(),
            preparation_cleanup_sequence: 1,
            reason,
            prepared_session_registration_digest: registration.registration_digest.clone(),
            cleanup_command_digest: digest,
        }
    }
    pub fn cleanup_command_id(&self) -> &str {
        &self.cleanup_command_id
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn proposed_run_id(&self) -> &str {
        &self.proposed_run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn preparation_cleanup_sequence(&self) -> u64 {
        self.preparation_cleanup_sequence
    }
    pub fn reason(&self) -> PreparationAbortReason {
        self.reason
    }
    pub fn prepared_session_registration_digest(&self) -> &str {
        &self.prepared_session_registration_digest
    }
    pub fn cleanup_command_digest(&self) -> &str {
        &self.cleanup_command_digest
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedSessionClosedReceipt {
    cleanup_command_id: String,
    preparation_id: String,
    proposed_run_id: String,
    session_handle: String,
    host_process_epoch: String,
    preparation_cleanup_sequence: u64,
    close_disposition: String,
    receipt_digest: String,
}

impl PreparedSessionClosedReceipt {
    pub fn from_cleanup(
        cleanup: &PreparedSessionCleanupEnvelope,
        session_handle: impl Into<String>,
        close_disposition: impl Into<String>,
        receipt_digest: impl Into<String>,
    ) -> Self {
        Self {
            cleanup_command_id: cleanup.cleanup_command_id.clone(),
            preparation_id: cleanup.preparation_id.clone(),
            proposed_run_id: cleanup.proposed_run_id.clone(),
            session_handle: session_handle.into(),
            host_process_epoch: cleanup.host_process_epoch.clone(),
            preparation_cleanup_sequence: cleanup.preparation_cleanup_sequence,
            close_disposition: close_disposition.into(),
            receipt_digest: receipt_digest.into(),
        }
    }
    pub fn matches_cleanup(&self, cleanup: &PreparedSessionCleanupEnvelope) -> bool {
        self.cleanup_command_id == cleanup.cleanup_command_id
            && self.preparation_id == cleanup.preparation_id
            && self.proposed_run_id == cleanup.proposed_run_id
            && self.session_handle == cleanup.session_handle
            && self.host_process_epoch == cleanup.host_process_epoch
            && self.preparation_cleanup_sequence == cleanup.preparation_cleanup_sequence
            && matches!(
                self.close_disposition.as_str(),
                "closed" | "already_closed" | "epoch_ended"
            )
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RenewalReplay {
    pub(crate) idempotency_key: String,
    #[serde(
        serialize_with = "serialize_persisted_preview",
        deserialize_with = "deserialize_persisted_preview"
    )]
    pub(crate) preview: RunPreparationPreview,
}
impl RenewalReplay {
    pub(crate) fn new(idempotency_key: String, preview: RunPreparationPreview) -> Self {
        Self {
            idempotency_key,
            preview,
        }
    }
    pub(crate) fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub(crate) fn preview(&self) -> &RunPreparationPreview {
        &self.preview
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct RunPreparationRecord {
    idempotency_key: String,
    #[serde(
        serialize_with = "serialize_persisted_preview",
        deserialize_with = "deserialize_persisted_preview"
    )]
    preview: RunPreparationPreview,
    state: RunPreparationState,
    registration: Option<PreparedSessionRegistration>,
    cleanup: Option<PreparedSessionCleanupEnvelope>,
    closed_receipt: Option<PreparedSessionClosedReceipt>,
    abort_idempotency_key: Option<String>,
    renewals: BTreeMap<String, RenewalReplay>,
}

impl RunPreparationRecord {
    pub(crate) fn new(idempotency_key: String, preview: RunPreparationPreview) -> Self {
        Self {
            idempotency_key,
            preview,
            state: RunPreparationState::Pending,
            registration: None,
            cleanup: None,
            closed_receipt: None,
            abort_idempotency_key: None,
            renewals: BTreeMap::new(),
        }
    }
    pub fn preview(&self) -> &RunPreparationPreview {
        &self.preview
    }
    pub(crate) fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub fn state(&self) -> RunPreparationState {
        self.state
    }
    pub fn registration(&self) -> Option<&PreparedSessionRegistration> {
        self.registration.as_ref()
    }
    pub fn cleanup(&self) -> Option<&PreparedSessionCleanupEnvelope> {
        self.cleanup.as_ref()
    }
    pub fn closed_receipt(&self) -> Option<&PreparedSessionClosedReceipt> {
        self.closed_receipt.as_ref()
    }
    pub(crate) fn preview_mut(&mut self) -> &mut RunPreparationPreview {
        &mut self.preview
    }
    pub(crate) fn set_lease_generation(&mut self, generation: u64) {
        self.preview.set_lease_generation(generation);
    }
    pub(crate) fn renewals_mut(&mut self) -> &mut BTreeMap<String, RenewalReplay> {
        &mut self.renewals
    }
    pub(crate) fn renewals(&self) -> &BTreeMap<String, RenewalReplay> {
        &self.renewals
    }
    pub(crate) fn register(&mut self, registration: PreparedSessionRegistration) {
        self.registration = Some(registration);
        self.state = RunPreparationState::Registered;
    }
    pub(crate) fn abort(&mut self, key: String, cleanup: Option<PreparedSessionCleanupEnvelope>) {
        self.abort_idempotency_key = Some(key);
        self.cleanup = cleanup;
        self.state = if self.cleanup.is_some() {
            RunPreparationState::Aborting
        } else {
            RunPreparationState::Closed
        };
    }
    pub(crate) fn close(&mut self, receipt: PreparedSessionClosedReceipt) {
        self.closed_receipt = Some(receipt);
        self.state = RunPreparationState::Closed;
    }
    pub(crate) fn close_for_epoch_end(&mut self) {
        self.state = RunPreparationState::Closed;
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparationError {
    code: &'static str,
    message: String,
}
impl PreparationError {
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
impl fmt::Display for PreparationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for PreparationError {}

fn serialize_persisted_preview<S>(
    preview: &RunPreparationPreview,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    let mut persisted = preview.clone();
    persisted.token.clear();
    persisted.serialize(serializer)
}

fn deserialize_persisted_preview<'de, D>(deserializer: D) -> Result<RunPreparationPreview, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let mut preview = RunPreparationPreview::deserialize(deserializer)?;
    preview.token.clear();
    Ok(preview)
}
