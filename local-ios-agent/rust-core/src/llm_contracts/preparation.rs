use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::{Deserialize, Serialize};

use super::{
    AgentLLMRequirements, GenerationDisclosureDocument, HostCommandPayload, LLMInputModality,
    LLMToolCallingMode,
};

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
pub struct FrozenInitialTurn {
    payload: HostCommandPayload,
    disclosure: GenerationDisclosureDocument,
}

impl FrozenInitialTurn {
    pub(crate) fn new(
        payload: HostCommandPayload,
        disclosure: GenerationDisclosureDocument,
    ) -> Self {
        Self {
            payload,
            disclosure,
        }
    }

    pub fn payload(&self) -> &HostCommandPayload {
        &self.payload
    }

    pub fn disclosure(&self) -> &GenerationDisclosureDocument {
        &self.disclosure
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
    initial_disclosure: GenerationDisclosureDocument,
    frozen_initial_turn: FrozenInitialTurn,
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
        frozen_initial_turn: FrozenInitialTurn,
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
            initial_disclosure: frozen_initial_turn.disclosure.clone(),
            frozen_initial_turn,
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
    pub fn initial_disclosure(&self) -> &GenerationDisclosureDocument {
        &self.initial_disclosure
    }
    pub fn frozen_initial_turn(&self) -> &FrozenInitialTurn {
        &self.frozen_initial_turn
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
pub struct HostAttestationV1Document {
    schema_version: String,
    preparation_id: String,
    proposed_run_id: String,
    session_id: String,
    swift_snapshot_id: String,
    prepared_session_registration_digest: String,
    binding_id: String,
    binding_revision: String,
    binding_hash: String,
    requirements_hash: String,
    disclosure_digest: String,
    capability_snapshot_digest: String,
    resolved_parameters_digest: String,
    host_process_epoch: String,
    expires_at: String,
    opaque_egress_subject_digest: String,
}

impl HostAttestationV1Document {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        preparation_id: impl Into<String>,
        proposed_run_id: impl Into<String>,
        session_id: impl Into<String>,
        swift_snapshot_id: impl Into<String>,
        prepared_session_registration_digest: impl Into<String>,
        binding_id: impl Into<String>,
        binding_revision: u64,
        binding_hash: impl Into<String>,
        requirements_hash: impl Into<String>,
        disclosure_digest: impl Into<String>,
        capability_snapshot_digest: impl Into<String>,
        resolved_parameters_digest: impl Into<String>,
        host_process_epoch: impl Into<String>,
        expires_at: impl Into<String>,
        opaque_egress_subject_digest: impl Into<String>,
    ) -> Self {
        Self {
            schema_version: "1".into(),
            preparation_id: preparation_id.into(),
            proposed_run_id: proposed_run_id.into(),
            session_id: session_id.into(),
            swift_snapshot_id: swift_snapshot_id.into(),
            prepared_session_registration_digest: prepared_session_registration_digest.into(),
            binding_id: binding_id.into(),
            binding_revision: binding_revision.to_string(),
            binding_hash: binding_hash.into(),
            requirements_hash: requirements_hash.into(),
            disclosure_digest: disclosure_digest.into(),
            capability_snapshot_digest: capability_snapshot_digest.into(),
            resolved_parameters_digest: resolved_parameters_digest.into(),
            host_process_epoch: host_process_epoch.into(),
            expires_at: expires_at.into(),
            opaque_egress_subject_digest: opaque_egress_subject_digest.into(),
        }
    }

    pub fn expected_digest(&self) -> Result<String, PreparationError> {
        let identity_is_canonical = self.schema_version == "1"
            && !self.preparation_id.is_empty()
            && !self.proposed_run_id.is_empty()
            && !self.session_id.is_empty()
            && !self.swift_snapshot_id.is_empty()
            && !self.binding_id.is_empty()
            && self
                .binding_revision
                .parse::<u64>()
                .ok()
                .map(|value| value.to_string())
                == Some(self.binding_revision.clone())
            && !self.host_process_epoch.is_empty();
        let digests_are_canonical = [
            &self.prepared_session_registration_digest,
            &self.binding_hash,
            &self.requirements_hash,
            &self.disclosure_digest,
            &self.capability_snapshot_digest,
            &self.resolved_parameters_digest,
            &self.opaque_egress_subject_digest,
        ]
        .into_iter()
        .all(|value| is_lowercase_sha256(value));
        if !identity_is_canonical
            || !digests_are_canonical
            || canonical_timestamp_to_millis(&self.expires_at).is_none()
        {
            return Err(PreparationError::new(
                "preparation.egress_attestation_document_invalid",
                "host attestation identity, digest, schema, or expiry is not canonical",
            ));
        }
        crate::canonical_digest::CanonicalDigestV1::digest("egress-attestation:v1", self)
            .map(|digest| digest.as_str().to_string())
            .map_err(|error| {
                PreparationError::new("preparation.egress_digest_failed", error.to_string())
            })
    }
    pub fn expiration_millis(&self) -> Option<u64> {
        canonical_timestamp_to_millis(&self.expires_at)
    }
    pub fn preparation_id(&self) -> &str {
        &self.preparation_id
    }
    pub fn proposed_run_id(&self) -> &str {
        &self.proposed_run_id
    }
    pub fn session_id(&self) -> &str {
        &self.session_id
    }
    pub fn swift_snapshot_id(&self) -> &str {
        &self.swift_snapshot_id
    }
    pub fn prepared_session_registration_digest(&self) -> &str {
        &self.prepared_session_registration_digest
    }
    pub fn binding_id(&self) -> &str {
        &self.binding_id
    }
    pub fn binding_revision(&self) -> &str {
        &self.binding_revision
    }
    pub fn binding_hash(&self) -> &str {
        &self.binding_hash
    }
    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }
    pub fn disclosure_digest(&self) -> &str {
        &self.disclosure_digest
    }
    pub fn capability_snapshot_digest(&self) -> &str {
        &self.capability_snapshot_digest
    }
    pub fn resolved_parameters_digest(&self) -> &str {
        &self.resolved_parameters_digest
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn opaque_egress_subject_digest(&self) -> &str {
        &self.opaque_egress_subject_digest
    }
}

fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostAttestation {
    document: HostAttestationV1Document,
    preparation_binding_digest: String,
    egress_attestation_digest: String,
    #[serde(default)]
    disclosure_grant_id: String,
    #[serde(default)]
    data_classes: BTreeMap<String, bool>,
    #[serde(default)]
    highest_sensitivity: String,
    #[serde(default)]
    capability_attestation: Option<PreparedCapabilityAttestation>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostRunHandle {
    run_id: String,
    session_handle: String,
    first_command_id: String,
}

impl HostRunHandle {
    pub fn new(
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        first_command_id: impl Into<String>,
    ) -> Self {
        Self {
            run_id: run_id.into(),
            session_handle: session_handle.into(),
            first_command_id: first_command_id.into(),
        }
    }
    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn first_command_id(&self) -> &str {
        &self.first_command_id
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PreparedSessionCleanupIdentity {
    cleanup_command_id: String,
    cleanup_command_sequence: u64,
    preparation_id: String,
    proposed_run_id: String,
    session_handle: String,
    registration_digest: String,
    host_process_epoch: String,
}

impl PreparedSessionCleanupIdentity {
    pub fn from_cleanup(cleanup: &PreparedSessionCleanupEnvelope) -> Self {
        Self {
            cleanup_command_id: cleanup.cleanup_command_id().to_string(),
            cleanup_command_sequence: cleanup.preparation_cleanup_sequence(),
            preparation_id: cleanup.preparation_id().to_string(),
            proposed_run_id: cleanup.proposed_run_id().to_string(),
            session_handle: cleanup.session_handle().to_string(),
            registration_digest: cleanup.prepared_session_registration_digest().to_string(),
            host_process_epoch: cleanup.host_process_epoch().to_string(),
        }
    }

    pub fn cleanup_command_id(&self) -> &str {
        &self.cleanup_command_id
    }

    pub fn cleanup_command_sequence(&self) -> u64 {
        self.cleanup_command_sequence
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

    pub fn registration_digest(&self) -> &str {
        &self.registration_digest
    }

    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum PreparationReconciliation {
    Committed {
        handle: HostRunHandle,
    },
    Pending,
    Aborting {
        cleanup_identity: PreparedSessionCleanupIdentity,
    },
}

impl HostAttestation {
    pub fn from_registration(
        registration: PreparedSessionRegistration,
        preparation_binding_digest: impl Into<String>,
        egress_attestation_digest: impl Into<String>,
        expiration_millis: u64,
    ) -> Self {
        let expires_at = canonical_timestamp_from_millis(expiration_millis);
        let document = HostAttestationV1Document::new(
            registration.preparation_id(),
            registration.proposed_run_id(),
            registration.session_handle(),
            registration.swift_snapshot_id(),
            registration.registration_digest(),
            registration.binding_id(),
            registration.binding_revision(),
            registration.binding_hash(),
            "",
            "",
            "",
            "",
            registration.host_process_epoch(),
            expires_at,
            "",
        );
        Self {
            document,
            preparation_binding_digest: preparation_binding_digest.into(),
            egress_attestation_digest: egress_attestation_digest.into(),
            disclosure_grant_id: String::new(),
            data_classes: BTreeMap::new(),
            highest_sensitivity: String::new(),
            capability_attestation: None,
        }
    }
    pub fn for_contract_fixture(document: HostAttestationV1Document) -> Self {
        Self {
            document,
            preparation_binding_digest: String::new(),
            egress_attestation_digest: String::new(),
            disclosure_grant_id: String::new(),
            data_classes: BTreeMap::new(),
            highest_sensitivity: String::new(),
            capability_attestation: None,
        }
    }
    pub fn document(&self) -> &HostAttestationV1Document {
        &self.document
    }
    pub fn preparation_binding_digest(&self) -> &str {
        &self.preparation_binding_digest
    }
    pub fn expiration_millis(&self) -> u64 {
        self.document.expiration_millis().unwrap_or(0)
    }
    pub fn egress_attestation_digest(&self) -> &str {
        &self.egress_attestation_digest
    }
    pub fn disclosure_digest(&self) -> &str {
        self.document.disclosure_digest()
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
        self.document.opaque_egress_subject_digest()
    }
    pub fn capability_attestation(&self) -> Option<&PreparedCapabilityAttestation> {
        self.capability_attestation.as_ref()
    }
    pub fn with_capability_attestation(
        mut self,
        capability_attestation: PreparedCapabilityAttestation,
    ) -> Self {
        self.document.capability_snapshot_digest =
            capability_attestation.attestation_digest().to_string();
        self.capability_attestation = Some(capability_attestation);
        self
    }
    pub fn with_document_context(
        mut self,
        requirements_hash: impl Into<String>,
        resolved_parameters_digest: impl Into<String>,
    ) -> Self {
        self.document.requirements_hash = requirements_hash.into();
        self.document.resolved_parameters_digest = resolved_parameters_digest.into();
        self
    }
    pub fn with_capability_snapshot_digest(mut self, digest: impl Into<String>) -> Self {
        self.document.capability_snapshot_digest = digest.into();
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
        self.document.disclosure_digest = disclosure_digest.into();
        self.disclosure_grant_id = disclosure_grant_id.into();
        self.data_classes = data_classes
            .into_iter()
            .map(|value| (value.into(), true))
            .collect();
        self.highest_sensitivity = highest_sensitivity.into();
        self.document.opaque_egress_subject_digest = opaque_subject_digest.into();
        self
    }
    pub fn with_computed_egress_digest(mut self) -> Result<Self, PreparationError> {
        self.egress_attestation_digest = self.expected_egress_digest()?;
        Ok(self)
    }
    pub fn expected_egress_digest(&self) -> Result<String, PreparationError> {
        self.document.expected_digest()
    }
}

fn canonical_timestamp_from_millis(millis: u64) -> String {
    let seconds = millis / 1_000;
    let millisecond = millis % 1_000;
    let days = seconds / 86_400;
    let second_of_day = seconds % 86_400;
    let (year, month, day) = civil_from_days(days as i64);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millisecond:03}Z",
        second_of_day / 3_600,
        (second_of_day % 3_600) / 60,
        second_of_day % 60
    )
}

fn canonical_timestamp_to_millis(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if bytes.len() != 24
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'.'
        || bytes[23] != b'Z'
    {
        return None;
    }
    let number = |start: usize, end: usize| value.get(start..end)?.parse::<u32>().ok();
    let year = number(0, 4)?;
    let month = number(5, 7)?;
    let day = number(8, 10)?;
    let hour = number(11, 13)?;
    let minute = number(14, 16)?;
    let second = number(17, 19)?;
    let millis = number(20, 23)?;
    if !(1..=12).contains(&month)
        || day == 0
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let days = days_from_civil(year as i64, month as i64, day as i64)?;
    u64::try_from(days)
        .ok()?
        .checked_mul(86_400_000)?
        .checked_add(
            hour as u64 * 3_600_000
                + minute as u64 * 60_000
                + second as u64 * 1_000
                + millis as u64,
        )
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400)) => {
            29
        }
        2 => 28,
        _ => 0,
    }
}

fn days_from_civil(year: i64, month: i64, day: i64) -> Option<i64> {
    let adjusted = year - i64::from(month <= 2);
    let era = adjusted.div_euclid(400);
    let yoe = adjusted - era * 400;
    let mp = month + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    (days >= 0).then_some(days)
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
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
            close_disposition,
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
