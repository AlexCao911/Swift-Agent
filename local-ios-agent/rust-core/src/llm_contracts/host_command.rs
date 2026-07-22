use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::canonical_digest::CanonicalDigestV1;

use super::PreparedSessionCleanupEnvelope;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostCommandKind {
    StartGeneration,
    ResumeGeneration,
    CancelGeneration,
    CloseSession,
    CapacityAvailable,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostSemanticContent {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modality: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attachment_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub media_type: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostSemanticMessage {
    pub role: String,
    pub content: Vec<HostSemanticContent>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostSourceRevision {
    pub source_id: String,
    pub revision: String,
    pub digest: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostAttachmentReference {
    pub attachment_id: String,
    pub revision: String,
    pub modality: String,
    pub media_type: String,
    pub content_digest: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostToolResult {
    pub call_id: String,
    pub tool_name: String,
    pub result: Value,
    pub is_error: bool,
    pub data_classes: Vec<String>,
    pub highest_sensitivity: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostCommandPayload {
    pub schema_version: String,
    pub model_input_id: String,
    pub messages: Vec<HostSemanticMessage>,
    pub tool_schema_json: String,
    pub tool_schema_digest: String,
    pub source_revisions: Vec<HostSourceRevision>,
    pub source_revisions_digest: String,
    pub attachments: Vec<HostAttachmentReference>,
    pub semantic_history: Vec<HostSemanticMessage>,
    pub tool_results: Vec<HostToolResult>,
}

impl HostCommandPayload {
    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        digest("host-command-payload:v1", self)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationDisclosureDocument {
    pub schema_version: String,
    pub generation_turn_id: String,
    pub content_digest: String,
    pub source_revision_digest: String,
    pub data_classes: Vec<String>,
    pub highest_sensitivity: String,
    pub safe_display_summary: SafeDisplaySummaryDocument,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SafeDisplaySummaryDocument {
    pub source_kinds: Vec<String>,
    pub added_item_counts: Vec<EgressDataClassCountDocument>,
    pub approximate_added_size: String,
    pub triggering_tool_display_keys: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EgressDataClassCountDocument {
    pub data_class: String,
    pub count: String,
}

impl GenerationDisclosureDocument {
    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        digest("generation-disclosure:v1", self)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostCommandEnvelope {
    pub schema_version: u32,
    pub command_id: String,
    pub run_id: String,
    pub session_handle: String,
    pub host_process_epoch: String,
    pub command_sequence: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_turn_id: Option<String>,
    pub kind: HostCommandKind,
    pub payload_digest: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disclosure_digest: Option<String>,
    pub command_envelope_digest: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disclosure: Option<GenerationDisclosureDocument>,
    pub payload: HostCommandPayload,
}

#[derive(Serialize)]
struct HostCommandEnvelopeDigestDocument<'a> {
    schema_version: u32,
    command_id: &'a str,
    run_id: &'a str,
    session_handle: &'a str,
    host_process_epoch: &'a str,
    command_sequence: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    generation_turn_id: Option<&'a str>,
    kind: HostCommandKind,
    payload_digest: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    disclosure_digest: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    disclosure: Option<&'a GenerationDisclosureDocument>,
    payload: &'a HostCommandPayload,
}

impl HostCommandEnvelope {
    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        if self.payload.expected_digest()? != self.payload_digest {
            return Err(HostContractError::new(
                "llm.command.payload_digest_mismatch",
            ));
        }
        match (&self.disclosure, &self.disclosure_digest) {
            (Some(disclosure), Some(expected)) if disclosure.expected_digest()? == *expected => {}
            (None, None) => {}
            _ => {
                return Err(HostContractError::new(
                    "llm.command.disclosure_digest_mismatch",
                ))
            }
        }
        digest(
            "host-command-envelope:v1",
            &HostCommandEnvelopeDigestDocument {
                schema_version: self.schema_version,
                command_id: &self.command_id,
                run_id: &self.run_id,
                session_handle: &self.session_handle,
                host_process_epoch: &self.host_process_epoch,
                command_sequence: self.command_sequence,
                generation_turn_id: self.generation_turn_id.as_deref(),
                kind: self.kind,
                payload_digest: &self.payload_digest,
                disclosure_digest: self.disclosure_digest.as_deref(),
                disclosure: self.disclosure.as_ref(),
                payload: &self.payload,
            },
        )
    }
    pub fn payload(&self) -> &HostCommandPayload {
        &self.payload
    }
    pub fn command_id(&self) -> &str {
        &self.command_id
    }
    pub fn run_id(&self) -> &str {
        &self.run_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn host_process_epoch(&self) -> &str {
        &self.host_process_epoch
    }
    pub fn command_sequence(&self) -> u64 {
        self.command_sequence
    }
    pub fn kind(&self) -> HostCommandKind {
        self.kind
    }
    pub fn payload_digest(&self) -> &str {
        &self.payload_digest
    }
    pub fn command_envelope_digest(&self) -> &str {
        &self.command_envelope_digest
    }
}

impl HostCommandAcknowledgement {
    pub fn command_id(&self) -> &str {
        &self.command_id
    }
    pub fn session_handle(&self) -> &str {
        &self.session_handle
    }
    pub fn command_sequence(&self) -> u64 {
        self.command_sequence
    }
    pub fn command_envelope_digest(&self) -> &str {
        &self.command_envelope_digest
    }
    pub fn disposition(&self) -> HostCommandAcknowledgementDisposition {
        self.disposition
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostCommandCopyReceipt {
    Copied,
    Backpressure,
    HostUnavailable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostCommandAcknowledgementDisposition {
    Accepted,
    Rejected,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostCommandAcknowledgement {
    pub command_id: String,
    pub session_handle: String,
    pub command_sequence: u64,
    pub command_envelope_digest: String,
    pub disposition: HostCommandAcknowledgementDisposition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection_code: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostDispatchKind {
    Command,
    PreparedSessionCleanup,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct HostDispatchEnvelope {
    pub schema_version: u32,
    pub dispatch_kind: HostDispatchKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<HostCommandEnvelope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prepared_session_cleanup: Option<PreparedSessionCleanupEnvelope>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HostDispatchEnvelopeWire {
    schema_version: u32,
    dispatch_kind: HostDispatchKind,
    #[serde(default)]
    command: Option<HostCommandEnvelope>,
    #[serde(default)]
    prepared_session_cleanup: Option<PreparedSessionCleanupEnvelope>,
}

impl<'de> Deserialize<'de> for HostDispatchEnvelope {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let wire = HostDispatchEnvelopeWire::deserialize(deserializer)?;
        let envelope = Self {
            schema_version: wire.schema_version,
            dispatch_kind: wire.dispatch_kind,
            command: wire.command,
            prepared_session_cleanup: wire.prepared_session_cleanup,
        };
        envelope.validate().map_err(serde::de::Error::custom)?;
        Ok(envelope)
    }
}

impl HostDispatchEnvelope {
    pub fn validate(&self) -> Result<(), HostContractError> {
        let valid = match self.dispatch_kind {
            HostDispatchKind::Command => {
                self.command.is_some() && self.prepared_session_cleanup.is_none()
            }
            HostDispatchKind::PreparedSessionCleanup => {
                self.command.is_none() && self.prepared_session_cleanup.is_some()
            }
        };
        if self.schema_version == 1 && valid {
            Ok(())
        } else {
            Err(HostContractError::new("llm.dispatch.invalid"))
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HostContractError {
    code: &'static str,
    message: String,
}
impl HostContractError {
    pub(crate) fn new(code: &'static str) -> Self {
        Self {
            code,
            message: code.to_string(),
        }
    }
    pub fn code(&self) -> &str {
        self.code
    }
}
impl std::fmt::Display for HostContractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for HostContractError {}

fn digest<T: Serialize>(domain: &str, value: &T) -> Result<String, HostContractError> {
    CanonicalDigestV1::digest(domain, value)
        .map(|value| value.as_str().to_string())
        .map_err(|_| HostContractError::new("llm.contract.digest_failed"))
}
