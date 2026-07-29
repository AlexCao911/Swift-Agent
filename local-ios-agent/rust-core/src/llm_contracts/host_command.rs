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
    ExecuteToolBatch,
    CancelToolBatch,
    CloseSession,
    CapacityAvailable,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostSemanticMessage {
    pub role: String,
    pub content: Vec<HostSemanticContent>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostSourceRevision {
    pub source_id: String,
    pub revision: String,
    pub digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyHostAttachmentReference {
    pub attachment_id: String,
    pub revision: String,
    pub modality: String,
    pub media_type: String,
    pub content_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostModelMessage {
    pub role: String,
    pub content: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostAttachmentReference {
    pub attachment_id: String,
    pub display_name: String,
    pub media_type: String,
    pub modality: String,
    pub content_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostToolDefinition {
    pub name: String,
    pub description: String,
    pub input_schema: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostModelRequest {
    pub run_id: String,
    pub conversation_stream_id: String,
    pub system_prompt: String,
    pub ordered_messages: Vec<HostModelMessage>,
    pub attachment_references: Vec<HostAttachmentReference>,
    pub ordered_tool_definitions: Vec<HostToolDefinition>,
    pub purpose: ModelRequestPurpose,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelRequestPurpose {
    #[default]
    Generation,
    Compaction,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostToolCall {
    pub call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostToolBatch {
    pub batch_id: String,
    pub run_id: String,
    pub ordered_calls: Vec<HostToolCall>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostToolResult {
    pub call_id: String,
    pub tool_name: String,
    pub result: Value,
    pub is_error: bool,
    pub data_classes: Vec<String>,
    pub highest_sensitivity: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct HostCommandPayload {
    pub schema_version: String,
    pub model_input_id: String,
    pub messages: Vec<HostSemanticMessage>,
    pub tool_schema_json: String,
    pub tool_schema_digest: String,
    pub source_revisions: Vec<HostSourceRevision>,
    pub source_revisions_digest: String,
    pub attachments: Vec<LegacyHostAttachmentReference>,
    pub semantic_history: Vec<HostSemanticMessage>,
    pub tool_results: Vec<HostToolResult>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_stream_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ordered_messages: Vec<HostModelMessage>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachment_references: Vec<HostAttachmentReference>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ordered_tool_definitions: Vec<HostToolDefinition>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_request_purpose: Option<ModelRequestPurpose>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_batch: Option<HostToolBatch>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_batch_id: Option<String>,
}

impl HostCommandPayload {
    pub fn lifecycle() -> Self {
        Self {
            schema_version: "1".into(),
            model_input_id: "lifecycle".into(),
            messages: Vec::new(),
            tool_schema_json: "{}".into(),
            tool_schema_digest: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
                .into(),
            source_revisions: Vec::new(),
            source_revisions_digest:
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".into(),
            attachments: Vec::new(),
            semantic_history: Vec::new(),
            tool_results: Vec::new(),
            system_prompt: None,
            conversation_stream_id: None,
            ordered_messages: Vec::new(),
            attachment_references: Vec::new(),
            ordered_tool_definitions: Vec::new(),
            model_request_purpose: None,
            tool_batch: None,
            target_batch_id: None,
        }
    }

    pub fn generation_v2(request: HostModelRequest) -> Self {
        let mut payload = Self::empty_v2();
        payload.model_input_id = request.run_id;
        payload.system_prompt = Some(request.system_prompt);
        payload.conversation_stream_id = Some(request.conversation_stream_id);
        payload.ordered_messages = request.ordered_messages;
        payload.attachment_references = request.attachment_references;
        payload.ordered_tool_definitions = request.ordered_tool_definitions;
        payload.model_request_purpose = Some(request.purpose);
        payload
    }

    pub fn tool_batch_v2(batch: HostToolBatch) -> Self {
        let mut payload = Self::empty_v2();
        payload.tool_batch = Some(batch);
        payload
    }

    pub fn cancel_tool_batch_v2(batch_id: impl Into<String>) -> Self {
        let mut payload = Self::empty_v2();
        payload.target_batch_id = Some(batch_id.into());
        payload
    }

    pub fn lifecycle_v2() -> Self {
        Self::empty_v2()
    }

    pub fn model_request_v2(
        &self,
        kind: HostCommandKind,
        envelope_run_id: &str,
    ) -> Result<HostModelRequest, HostContractError> {
        self.validate_for(kind, envelope_run_id)?;
        Ok(HostModelRequest {
            run_id: envelope_run_id.to_string(),
            conversation_stream_id: self
                .conversation_stream_id
                .clone()
                .ok_or_else(command_payload_mismatch)?,
            system_prompt: self
                .system_prompt
                .clone()
                .ok_or_else(command_payload_mismatch)?,
            ordered_messages: self.ordered_messages.clone(),
            attachment_references: self.attachment_references.clone(),
            ordered_tool_definitions: self.ordered_tool_definitions.clone(),
            purpose: self
                .model_request_purpose
                .ok_or_else(command_payload_mismatch)?,
        })
    }

    pub fn validate_for(
        &self,
        kind: HostCommandKind,
        envelope_run_id: &str,
    ) -> Result<(), HostContractError> {
        if self.schema_version == "1" {
            return if self.v2_body_is_empty()
                && matches!(
                    kind,
                    HostCommandKind::StartGeneration
                        | HostCommandKind::ResumeGeneration
                        | HostCommandKind::CancelGeneration
                        | HostCommandKind::CloseSession
                        | HostCommandKind::CapacityAvailable
                ) {
                Ok(())
            } else {
                Err(command_payload_mismatch())
            };
        }
        if self.schema_version != "2" || !self.legacy_collections_are_empty() {
            return Err(command_payload_mismatch());
        }

        let generation_body_is_empty = self.system_prompt.is_none()
            && self.conversation_stream_id.is_none()
            && self.ordered_messages.is_empty()
            && self.attachment_references.is_empty()
            && self.ordered_tool_definitions.is_empty()
            && self.model_request_purpose.is_none();
        let valid = match kind {
            HostCommandKind::StartGeneration | HostCommandKind::ResumeGeneration => {
                self.model_input_id == envelope_run_id
                    && self.system_prompt.is_some()
                    && self
                        .conversation_stream_id
                        .as_deref()
                        .is_some_and(|stream_id| !stream_id.is_empty())
                    && self.tool_batch.is_none()
                    && self.target_batch_id.is_none()
                    && self.model_request_purpose.is_some()
            }
            HostCommandKind::ExecuteToolBatch => {
                generation_body_is_empty
                    && self
                        .tool_batch
                        .as_ref()
                        .is_some_and(|batch| batch.run_id == envelope_run_id)
                    && self.target_batch_id.is_none()
            }
            HostCommandKind::CancelToolBatch => {
                generation_body_is_empty
                    && self.tool_batch.is_none()
                    && self
                        .target_batch_id
                        .as_deref()
                        .is_some_and(|batch_id| !batch_id.is_empty())
            }
            HostCommandKind::CancelGeneration
            | HostCommandKind::CloseSession
            | HostCommandKind::CapacityAvailable => {
                generation_body_is_empty
                    && self.tool_batch.is_none()
                    && self.target_batch_id.is_none()
            }
        };
        if valid {
            Ok(())
        } else {
            Err(command_payload_mismatch())
        }
    }

    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        digest(self.digest_domain()?, self)
    }

    pub fn agent_input_digest(&self) -> Result<String, HostContractError> {
        digest("agent-input:v1", &self.agent_input_document()?)
    }

    pub(crate) fn canonical_agent_input(&self) -> Result<Vec<u8>, HostContractError> {
        CanonicalDigestV1::canonicalize(&self.agent_input_document()?)
            .map_err(|_| HostContractError::new("llm.contract.digest_failed"))
    }

    fn agent_input_document(&self) -> Result<Value, HostContractError> {
        if self.schema_version != "1" {
            return Err(HostContractError::new(
                "llm.contract.agent_input_schema_unsupported",
            ));
        }
        if !self.attachments.is_empty() {
            return Err(HostContractError::new(
                "llm.contract.attachment_resolution_unavailable",
            ));
        }
        let canonical_tool_schema: Value = serde_json::from_str(&self.tool_schema_json)
            .map_err(|_| HostContractError::new("llm.contract.tool_schema_invalid"))?;
        let messages = self
            .messages
            .iter()
            .map(|message| {
                serde_json::json!({
                    "content": message.content.iter().map(|content| {
                        if content.kind == "text" {
                            serde_json::json!({
                                "text": content.text,
                                "type": "text",
                            })
                        } else {
                            serde_json::json!({
                                "attachment_id": content.attachment_id,
                                "media_type": content.media_type,
                                "modality": content.modality,
                                "type": "attachment",
                            })
                        }
                    }).collect::<Vec<_>>(),
                    "role": if message.role == "summary" {
                        "system"
                    } else {
                        message.role.as_str()
                    },
                })
            })
            .collect::<Vec<_>>();
        let tool_results = self
            .tool_results
            .iter()
            .map(|result| {
                let mut data_classes = result.data_classes.clone();
                data_classes.sort();
                serde_json::json!({
                    "call_id": result.call_id,
                    "data_classes": data_classes,
                    "highest_sensitivity": result.highest_sensitivity,
                    "is_error": result.is_error,
                    "result": result.result,
                    "tool_name": result.tool_name,
                })
            })
            .collect::<Vec<_>>();
        Ok(serde_json::json!({
            "canonical_tool_schema": canonical_tool_schema,
            "input_id": self.model_input_id,
            "messages": messages,
            "provider_required_semantic_history": self.semantic_history,
            "resolved_attachments": [],
            "schema_version": "1",
            "tool_results": tool_results,
        }))
    }

    fn empty_v2() -> Self {
        let mut payload = Self::lifecycle();
        payload.schema_version = "2".into();
        payload
    }

    fn legacy_collections_are_empty(&self) -> bool {
        self.messages.is_empty()
            && self.source_revisions.is_empty()
            && self.attachments.is_empty()
            && self.semantic_history.is_empty()
            && self.tool_results.is_empty()
            && self.tool_schema_json == "{}"
            && self.tool_schema_digest
                == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
            && self.source_revisions_digest
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    }

    fn v2_body_is_empty(&self) -> bool {
        self.system_prompt.is_none()
            && self.conversation_stream_id.is_none()
            && self.ordered_messages.is_empty()
            && self.attachment_references.is_empty()
            && self.ordered_tool_definitions.is_empty()
            && self.model_request_purpose.is_none()
            && self.tool_batch.is_none()
            && self.target_batch_id.is_none()
    }

    fn digest_domain(&self) -> Result<&'static str, HostContractError> {
        match self.schema_version.as_str() {
            "1" => Ok("host-command-payload:v1"),
            "2" => Ok("host-command-payload:v2"),
            _ => Err(command_payload_mismatch()),
        }
    }

    fn envelope_schema_version(&self) -> Result<u32, HostContractError> {
        match self.schema_version.as_str() {
            "1" => Ok(1),
            "2" => Ok(2),
            _ => Err(command_payload_mismatch()),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SafeDisplaySummaryDocument {
    pub source_kinds: Vec<String>,
    pub added_item_counts: Vec<EgressDataClassCountDocument>,
    pub approximate_added_size: String,
    pub triggering_tool_display_keys: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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
    pub fn start_generation(
        command_id: impl Into<String>,
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        host_process_epoch: impl Into<String>,
        payload: HostCommandPayload,
        disclosure: GenerationDisclosureDocument,
    ) -> Result<Self, HostContractError> {
        let run_id = run_id.into();
        payload.validate_for(HostCommandKind::StartGeneration, &run_id)?;
        let payload_digest = payload.expected_digest()?;
        let disclosure_digest = disclosure.expected_digest()?;
        let mut envelope = Self {
            schema_version: payload.envelope_schema_version()?,
            command_id: command_id.into(),
            run_id,
            session_handle: session_handle.into(),
            host_process_epoch: host_process_epoch.into(),
            command_sequence: 1,
            generation_turn_id: Some(disclosure.generation_turn_id.clone()),
            kind: HostCommandKind::StartGeneration,
            payload_digest,
            disclosure_digest: Some(disclosure_digest),
            command_envelope_digest: String::new(),
            disclosure: Some(disclosure),
            payload,
        };
        envelope.command_envelope_digest = envelope.expected_digest()?;
        Ok(envelope)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn resume_generation(
        command_id: impl Into<String>,
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        host_process_epoch: impl Into<String>,
        command_sequence: u64,
        payload: HostCommandPayload,
        disclosure: GenerationDisclosureDocument,
    ) -> Result<Self, HostContractError> {
        let run_id = run_id.into();
        payload.validate_for(HostCommandKind::ResumeGeneration, &run_id)?;
        let payload_digest = payload.expected_digest()?;
        let disclosure_digest = disclosure.expected_digest()?;
        let mut envelope = Self {
            schema_version: payload.envelope_schema_version()?,
            command_id: command_id.into(),
            run_id,
            session_handle: session_handle.into(),
            host_process_epoch: host_process_epoch.into(),
            command_sequence,
            generation_turn_id: Some(disclosure.generation_turn_id.clone()),
            kind: HostCommandKind::ResumeGeneration,
            payload_digest,
            disclosure_digest: Some(disclosure_digest),
            command_envelope_digest: String::new(),
            disclosure: Some(disclosure),
            payload,
        };
        envelope.command_envelope_digest = envelope.expected_digest()?;
        Ok(envelope)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn lifecycle(
        command_id: impl Into<String>,
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        host_process_epoch: impl Into<String>,
        command_sequence: u64,
        kind: HostCommandKind,
    ) -> Result<Self, HostContractError> {
        if matches!(
            kind,
            HostCommandKind::StartGeneration | HostCommandKind::ResumeGeneration
        ) {
            return Err(HostContractError::new("llm.command.lifecycle_kind_invalid"));
        }
        let payload = HostCommandPayload::lifecycle();
        let payload_digest = payload.expected_digest()?;
        let mut envelope = Self {
            schema_version: 1,
            command_id: command_id.into(),
            run_id: run_id.into(),
            session_handle: session_handle.into(),
            host_process_epoch: host_process_epoch.into(),
            command_sequence,
            generation_turn_id: None,
            kind,
            payload_digest,
            disclosure_digest: None,
            command_envelope_digest: String::new(),
            disclosure: None,
            payload,
        };
        envelope.command_envelope_digest = envelope.expected_digest()?;
        Ok(envelope)
    }

    pub fn expected_digest(&self) -> Result<String, HostContractError> {
        self.payload.validate_for(self.kind, &self.run_id)?;
        let domain = match (self.schema_version, self.payload.schema_version.as_str()) {
            (1, "1") => "host-command-envelope:v1",
            (2, "2") => "host-command-envelope:v2",
            _ => return Err(command_payload_mismatch()),
        };
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
            domain,
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

    #[allow(clippy::too_many_arguments)]
    pub fn command_v2(
        command_id: impl Into<String>,
        run_id: impl Into<String>,
        session_handle: impl Into<String>,
        host_process_epoch: impl Into<String>,
        command_sequence: u64,
        kind: HostCommandKind,
        payload: HostCommandPayload,
    ) -> Result<Self, HostContractError> {
        if matches!(
            kind,
            HostCommandKind::StartGeneration | HostCommandKind::ResumeGeneration
        ) {
            return Err(HostContractError::new("llm.command.lifecycle_kind_invalid"));
        }
        let run_id = run_id.into();
        payload.validate_for(kind, &run_id)?;
        let payload_digest = payload.expected_digest()?;
        let mut envelope = Self {
            schema_version: 2,
            command_id: command_id.into(),
            run_id,
            session_handle: session_handle.into(),
            host_process_epoch: host_process_epoch.into(),
            command_sequence,
            generation_turn_id: None,
            kind,
            payload_digest,
            disclosure_digest: None,
            command_envelope_digest: String::new(),
            disclosure: None,
            payload,
        };
        envelope.command_envelope_digest = envelope.expected_digest()?;
        Ok(envelope)
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
    pub fn rejection_code(&self) -> Option<&str> {
        self.rejection_code.as_deref()
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
    pub fn command(command: HostCommandEnvelope) -> Self {
        Self {
            schema_version: 1,
            dispatch_kind: HostDispatchKind::Command,
            command: Some(command),
            prepared_session_cleanup: None,
        }
    }

    pub fn prepared_session_cleanup(cleanup: PreparedSessionCleanupEnvelope) -> Self {
        Self {
            schema_version: 1,
            dispatch_kind: HostDispatchKind::PreparedSessionCleanup,
            command: None,
            prepared_session_cleanup: Some(cleanup),
        }
    }

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

fn command_payload_mismatch() -> HostContractError {
    HostContractError::new("llm.contract.command_payload_mismatch")
}
