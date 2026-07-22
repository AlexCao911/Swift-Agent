use serde::{Deserialize, Serialize};

use crate::canonical_digest::CanonicalDigestV1;

use super::HostContractError;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LLMEventKind {
    GenerationStarted,
    TextDelta,
    ReasoningSummaryDelta,
    ToolCallStarted,
    ToolCallArgumentsDelta,
    ToolCallCompleted,
    UsageUpdated,
    GenerationCompleted,
    Failed,
    Cancelled,
    SessionClosed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LLMBackendCompletionWire {
    pub outcome: String,
    pub ordered_call_ids: Vec<String>,
    pub finish_reason: String,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LLMEventPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arguments_json: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completion: Option<LLMBackendCompletionWire>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opaque_operation_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub close_disposition: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LLMEventEnvelope {
    pub schema_version: u32,
    pub event_id: String,
    pub run_id: String,
    pub session_handle: String,
    pub host_process_epoch: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_turn_id: Option<String>,
    pub event_sequence: u64,
    pub kind: LLMEventKind,
    pub payload: LLMEventPayload,
    pub event_envelope_digest: String,
}

#[derive(Serialize)]
struct EventDigestDocument<'a> {
    schema_version: u32,
    event_id: &'a str,
    run_id: &'a str,
    session_handle: &'a str,
    host_process_epoch: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    generation_turn_id: Option<&'a str>,
    event_sequence: u64,
    kind: LLMEventKind,
    payload: &'a LLMEventPayload,
}

impl LLMEventEnvelope {
    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        digest(
            "llm-event-envelope:v1",
            &EventDigestDocument {
                schema_version: self.schema_version,
                event_id: &self.event_id,
                run_id: &self.run_id,
                session_handle: &self.session_handle,
                host_process_epoch: &self.host_process_epoch,
                generation_turn_id: self.generation_turn_id.as_deref(),
                event_sequence: self.event_sequence,
                kind: self.kind,
                payload: &self.payload,
            },
        )
    }
    pub fn event_envelope_digest(&self) -> &str {
        &self.event_envelope_digest
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LLMEventReceiptDisposition {
    Accepted,
    TerminallyIgnored,
    Closed,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LLMEventReceipt {
    pub schema_version: u32,
    pub run_id: String,
    pub session_handle: String,
    pub host_process_epoch: String,
    pub event_sequence: u64,
    pub event_id: String,
    pub event_envelope_digest: String,
    pub disposition: LLMEventReceiptDisposition,
    pub receipt_digest: String,
}

#[derive(Serialize)]
struct ReceiptDigestDocument<'a> {
    schema_version: u32,
    run_id: &'a str,
    session_handle: &'a str,
    host_process_epoch: &'a str,
    event_sequence: u64,
    event_id: &'a str,
    event_envelope_digest: &'a str,
    disposition: LLMEventReceiptDisposition,
}

impl LLMEventReceipt {
    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        digest(
            "llm-event-receipt:v1",
            &ReceiptDigestDocument {
                schema_version: self.schema_version,
                run_id: &self.run_id,
                session_handle: &self.session_handle,
                host_process_epoch: &self.host_process_epoch,
                event_sequence: self.event_sequence,
                event_id: &self.event_id,
                event_envelope_digest: &self.event_envelope_digest,
                disposition: self.disposition,
            },
        )
    }
    pub fn receipt_digest(&self) -> &str {
        &self.receipt_digest
    }
    pub fn event_envelope_digest(&self) -> &str {
        &self.event_envelope_digest
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SequenceEffect {
    ConsumeNew,
    AlreadyConsumed,
    DoNotConsume,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LLMEventSubmissionResult {
    Accepted,
    Duplicate,
    Backpressure,
    StaleSession,
    TurnTerminal,
    GenerationTerminal,
    ClosedSession,
    SequenceGap,
    SequenceConflict,
    IdentityConflict,
    InvalidEnvelope,
    PayloadTooLarge,
}

impl LLMEventSubmissionResult {
    pub fn sequence_effect(self) -> SequenceEffect {
        match self {
            Self::Duplicate => SequenceEffect::AlreadyConsumed,
            Self::Accepted | Self::TurnTerminal | Self::GenerationTerminal => {
                SequenceEffect::ConsumeNew
            }
            _ => SequenceEffect::DoNotConsume,
        }
    }
    pub fn retry_same_envelope(self) -> bool {
        self == Self::Backpressure
    }
}

fn digest<T: Serialize>(domain: &str, value: &T) -> Result<String, HostContractError> {
    CanonicalDigestV1::digest(domain, value)
        .map(|value| value.as_str().to_string())
        .map_err(|_| HostContractError::new("llm.contract.digest_failed"))
}
