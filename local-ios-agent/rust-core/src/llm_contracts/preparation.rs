use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

use super::{AgentLLMRequirements, LLMInputModality, LLMToolCallingMode};

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
    #[serde(default)]
    requirements: Option<AgentLLMRequirements>,
    #[serde(default)]
    initial_data_classes: BTreeSet<String>,
    #[serde(default)]
    initial_highest_sensitivity: String,
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
            requirements: None,
            initial_data_classes: BTreeSet::new(),
            initial_highest_sensitivity: String::new(),
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
    pub fn conversation_frame_digest(&self) -> &str {
        &self.conversation_frame_digest
    }
    pub fn execution_plan_digest(&self) -> &str {
        &self.execution_plan_digest
    }
    pub fn tool_schema_digest(&self) -> &str {
        &self.tool_schema_digest
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
    pub fn initial_disclosure_digest(&self) -> &str {
        &self.initial_disclosure_digest
    }
    pub fn requirements(&self) -> Option<&AgentLLMRequirements> {
        self.requirements.as_ref()
    }
    pub fn initial_data_classes(&self) -> &BTreeSet<String> {
        &self.initial_data_classes
    }
    pub fn initial_highest_sensitivity(&self) -> &str {
        &self.initial_highest_sensitivity
    }
    pub fn with_requirements(mut self, requirements: AgentLLMRequirements) -> Self {
        self.requirements = Some(requirements);
        self
    }
    pub fn with_disclosure_public_fields(
        mut self,
        data_classes: impl IntoIterator<Item = impl Into<String>>,
        highest_sensitivity: impl Into<String>,
    ) -> Self {
        self.initial_data_classes = data_classes.into_iter().map(Into::into).collect();
        self.initial_highest_sensitivity = highest_sensitivity.into();
        self
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RunPreparationRequest {
    idempotency_key: String,
    preparation_id: String,
    proposed_run_id: String,
    binding: PreparationBinding,
}

impl RunPreparationRequest {
    pub(crate) fn new(
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
    pub(crate) fn idempotency_key(&self) -> &str {
        &self.idempotency_key
    }
    pub(crate) fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub(crate) fn proposed_run_id(&self) -> &str {
        &self.proposed_run_id
    }
    pub(crate) fn binding(&self) -> &PreparationBinding {
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
    #[serde(default)]
    binding_id: String,
    #[serde(default)]
    binding_revision: u64,
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
            binding_id: String::new(),
            binding_revision: 0,
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
    pub fn binding_id(&self) -> &str {
        &self.binding_id
    }
    pub fn binding_revision(&self) -> u64 {
        self.binding_revision
    }
    pub fn registration_digest(&self) -> &str {
        &self.registration_digest
    }
    pub fn with_binding_identity(
        mut self,
        binding_id: impl Into<String>,
        binding_revision: u64,
    ) -> Self {
        self.binding_id = binding_id.into();
        self.binding_revision = binding_revision;
        self
    }
    pub fn with_computed_digest(mut self) -> Result<Self, PreparationError> {
        self.registration_digest = self.expected_digest()?;
        Ok(self)
    }
    pub fn expected_digest(&self) -> Result<String, PreparationError> {
        #[derive(Serialize)]
        struct Document<'a> {
            preparation_id: &'a str,
            proposed_run_id: &'a str,
            session_handle: &'a str,
            swift_snapshot_id: &'a str,
            host_process_epoch: &'a str,
            binding_id: &'a str,
            binding_revision: u64,
            binding_hash: &'a str,
        }
        crate::canonical_digest::CanonicalDigestV1::digest(
            "prepared-session-registration:v1",
            &Document {
                preparation_id: &self.preparation_id,
                proposed_run_id: &self.proposed_run_id,
                session_handle: &self.session_handle,
                swift_snapshot_id: &self.swift_snapshot_id,
                host_process_epoch: &self.host_process_epoch,
                binding_id: &self.binding_id,
                binding_revision: self.binding_revision,
                binding_hash: &self.binding_hash,
            },
        )
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| {
            PreparationError::new("preparation.registration_digest_failed", error.to_string())
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostAttestation {
    registration: PreparedSessionRegistration,
    preparation_binding_digest: String,
    egress_attestation_digest: String,
    #[serde(default)]
    disclosure_digest: String,
    #[serde(default)]
    disclosure_grant_id: String,
    #[serde(default)]
    data_classes: BTreeMap<String, bool>,
    #[serde(default)]
    highest_sensitivity: String,
    #[serde(default)]
    opaque_subject_digest: String,
    #[serde(default)]
    capability_attestation: Option<PreparedCapabilityAttestation>,
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
            disclosure_digest: String::new(),
            disclosure_grant_id: String::new(),
            data_classes: BTreeMap::new(),
            highest_sensitivity: String::new(),
            opaque_subject_digest: String::new(),
            capability_attestation: None,
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
    pub fn egress_attestation_digest(&self) -> &str {
        &self.egress_attestation_digest
    }
    pub fn disclosure_digest(&self) -> &str {
        &self.disclosure_digest
    }
    pub fn disclosure_grant_id(&self) -> &str {
        &self.disclosure_grant_id
    }
    pub fn data_classes(&self) -> impl Iterator<Item = &str> {
        self.data_classes.keys().map(String::as_str)
    }
    pub fn highest_sensitivity(&self) -> &str {
        &self.highest_sensitivity
    }
    pub fn opaque_subject_digest(&self) -> &str {
        &self.opaque_subject_digest
    }
    pub fn capability_attestation(&self) -> Option<&PreparedCapabilityAttestation> {
        self.capability_attestation.as_ref()
    }
    pub fn with_capability_attestation(
        mut self,
        capability_attestation: PreparedCapabilityAttestation,
    ) -> Self {
        self.capability_attestation = Some(capability_attestation);
        self
    }
    pub fn with_egress_scope(
        mut self,
        disclosure_digest: impl Into<String>,
        disclosure_grant_id: impl Into<String>,
        data_classes: impl IntoIterator<Item = impl Into<String>>,
        highest_sensitivity: impl Into<String>,
        opaque_subject_digest: impl Into<String>,
    ) -> Self {
        self.disclosure_digest = disclosure_digest.into();
        self.disclosure_grant_id = disclosure_grant_id.into();
        self.data_classes = data_classes
            .into_iter()
            .map(|value| (value.into(), true))
            .collect();
        self.highest_sensitivity = highest_sensitivity.into();
        self.opaque_subject_digest = opaque_subject_digest.into();
        self
    }
    pub fn with_computed_egress_digest(mut self) -> Result<Self, PreparationError> {
        self.egress_attestation_digest = self.expected_egress_digest()?;
        Ok(self)
    }
    pub fn expected_egress_digest(&self) -> Result<String, PreparationError> {
        #[derive(Serialize)]
        struct Document<'a> {
            preparation_binding_digest: &'a str,
            registration_digest: &'a str,
            disclosure_digest: &'a str,
            disclosure_grant_id: &'a str,
            data_classes: Vec<&'a str>,
            highest_sensitivity: &'a str,
            opaque_subject_digest: &'a str,
        }
        crate::canonical_digest::CanonicalDigestV1::digest(
            "egress-attestation:v1",
            &Document {
                preparation_binding_digest: &self.preparation_binding_digest,
                registration_digest: self.registration.registration_digest(),
                disclosure_digest: &self.disclosure_digest,
                disclosure_grant_id: &self.disclosure_grant_id,
                data_classes: self.data_classes.keys().map(String::as_str).collect(),
                highest_sensitivity: &self.highest_sensitivity,
                opaque_subject_digest: &self.opaque_subject_digest,
            },
        )
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| {
            PreparationError::new("preparation.egress_digest_failed", error.to_string())
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedCapabilityAttestation {
    supported_capabilities: BTreeSet<String>,
    input_modalities: BTreeSet<LLMInputModality>,
    context_length: String,
    streaming: bool,
    tool_calling: bool,
    expiration_millis: u64,
    attestation_digest: String,
}

impl PreparedCapabilityAttestation {
    pub fn from_requirements(requirements: &AgentLLMRequirements, expiration_millis: u64) -> Self {
        Self {
            supported_capabilities: requirements
                .capability_requirements()
                .iter()
                .map(|requirement| requirement.as_str().to_string())
                .collect(),
            input_modalities: requirements.input_modalities().clone(),
            context_length: requirements.context_budget().to_string(),
            streaming: requirements.streaming_required(),
            tool_calling: requirements.tool_calling_mode() != LLMToolCallingMode::Disabled,
            expiration_millis,
            attestation_digest: String::new(),
        }
    }

    pub fn with_computed_digest(mut self) -> Result<Self, PreparationError> {
        self.attestation_digest = self.expected_digest()?;
        Ok(self)
    }
    pub fn with_context_length(mut self, context_length: impl Into<String>) -> Self {
        self.context_length = context_length.into();
        self
    }
    pub fn with_input_modalities(
        mut self,
        modalities: impl IntoIterator<Item = LLMInputModality>,
    ) -> Self {
        self.input_modalities = modalities.into_iter().collect();
        self
    }
    pub fn with_streaming(mut self, streaming: bool) -> Self {
        self.streaming = streaming;
        self
    }
    pub fn with_tool_calling(mut self, tool_calling: bool) -> Self {
        self.tool_calling = tool_calling;
        self
    }
    pub fn with_expiration(mut self, expiration_millis: u64) -> Self {
        self.expiration_millis = expiration_millis;
        self
    }
    pub fn with_attestation_digest(mut self, digest: impl Into<String>) -> Self {
        self.attestation_digest = digest.into();
        self
    }

    pub fn expected_digest(&self) -> Result<String, PreparationError> {
        #[derive(Serialize)]
        struct Document<'a> {
            supported_capabilities: Vec<&'a str>,
            input_modalities: &'a BTreeSet<LLMInputModality>,
            context_length: &'a str,
            streaming: bool,
            tool_calling: bool,
            expiration_millis: u64,
        }
        crate::canonical_digest::CanonicalDigestV1::digest(
            "capability-attestation:v1",
            &Document {
                supported_capabilities: self
                    .supported_capabilities
                    .iter()
                    .map(String::as_str)
                    .collect(),
                input_modalities: &self.input_modalities,
                context_length: &self.context_length,
                streaming: self.streaming,
                tool_calling: self.tool_calling,
                expiration_millis: self.expiration_millis,
            },
        )
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| {
            PreparationError::new("preparation.capability_digest_failed", error.to_string())
        })
    }

    pub fn attestation_digest(&self) -> &str {
        &self.attestation_digest
    }
    pub fn supported_capabilities(&self) -> &BTreeSet<String> {
        &self.supported_capabilities
    }
    pub fn input_modalities(&self) -> &BTreeSet<LLMInputModality> {
        &self.input_modalities
    }
    pub fn context_length(&self) -> &str {
        &self.context_length
    }
    pub fn streaming(&self) -> bool {
        self.streaming
    }
    pub fn tool_calling(&self) -> bool {
        self.tool_calling
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedSessionCleanupAcknowledgement {
    cleanup_command_id: String,
    preparation_id: String,
    preparation_cleanup_sequence: u64,
    cleanup_command_digest: String,
}

impl PreparedSessionCleanupAcknowledgement {
    pub fn from_cleanup(cleanup: &PreparedSessionCleanupEnvelope) -> Self {
        Self {
            cleanup_command_id: cleanup.cleanup_command_id.clone(),
            preparation_id: cleanup.preparation_id.clone(),
            preparation_cleanup_sequence: cleanup.preparation_cleanup_sequence,
            cleanup_command_digest: cleanup.cleanup_command_digest.clone(),
        }
    }

    pub fn matches_cleanup(&self, cleanup: &PreparedSessionCleanupEnvelope) -> bool {
        self.cleanup_command_id == cleanup.cleanup_command_id
            && self.preparation_id == cleanup.preparation_id
            && self.preparation_cleanup_sequence == cleanup.preparation_cleanup_sequence
            && self.cleanup_command_digest == cleanup.cleanup_command_digest
    }

    pub fn cleanup_command_id(&self) -> &str {
        &self.cleanup_command_id
    }

    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }

    pub fn preparation_cleanup_sequence(&self) -> u64 {
        self.preparation_cleanup_sequence
    }

    pub fn cleanup_command_digest(&self) -> &str {
        &self.cleanup_command_digest
    }
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
    close_disposition: PreparedSessionCloseDisposition,
    receipt_digest: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PreparedSessionCloseDisposition {
    Closed,
    AlreadyClosed,
}

impl PreparedSessionCloseDisposition {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Closed => "closed",
            Self::AlreadyClosed => "already_closed",
        }
    }
}

impl PreparedSessionClosedReceipt {
    pub fn from_cleanup(
        cleanup: &PreparedSessionCleanupEnvelope,
        session_handle: impl Into<String>,
        close_disposition: PreparedSessionCloseDisposition,
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
                self.close_disposition,
                PreparedSessionCloseDisposition::Closed
                    | PreparedSessionCloseDisposition::AlreadyClosed
            )
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn receipt_digest(&self) -> &str {
        &self.receipt_digest
    }
    pub fn close_disposition(&self) -> &str {
        self.close_disposition.as_str()
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
    #[serde(default)]
    cleanup_acknowledgement: Option<PreparedSessionCleanupAcknowledgement>,
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
            cleanup_acknowledgement: None,
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
    pub fn cleanup_acknowledgement(&self) -> Option<&PreparedSessionCleanupAcknowledgement> {
        self.cleanup_acknowledgement.as_ref()
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
    pub(crate) fn acknowledge_cleanup(
        &mut self,
        acknowledgement: PreparedSessionCleanupAcknowledgement,
    ) {
        self.cleanup_acknowledgement = Some(acknowledgement);
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
