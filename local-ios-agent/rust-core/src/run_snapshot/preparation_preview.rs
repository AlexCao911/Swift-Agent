use std::collections::BTreeSet;

use serde::Serialize;

use crate::canonical_digest::CanonicalDigestV1;
use crate::context::ModelInputRole;
use crate::conversation::ConversationRunFrame;
use crate::execution::ExecutionContextInputAssembler;
use crate::llm_contracts::{
    EgressDataClassCountDocument, GenerationDisclosureDocument, HostAttachmentReference,
    HostCommandPayload, HostSemanticContent, HostSemanticMessage, HostSourceRevision,
    PreparationBinding, SafeDisplaySummaryDocument,
};
use crate::run_snapshot::{RunSnapshotError, RunSnapshotResult, StartRunRequest};
use crate::user_customization::AgentSlotKind;

use super::resolver::HostSlotPreparationSources;

pub(crate) struct AuthoritativePreparationInput {
    pub(crate) binding: PreparationBinding,
    pub(crate) frozen_turn: FrozenGenerationTurn,
}

#[derive(Clone)]
pub(crate) struct FrozenGenerationTurn {
    pub(crate) start_request: StartRunRequest,
    pub(crate) sources: HostSlotPreparationSources,
    pub(crate) canonical_model_input: Vec<u8>,
    pub(crate) payload: HostCommandPayload,
    pub(crate) payload_digest: String,
    pub(crate) disclosure: GenerationDisclosureDocument,
    pub(crate) disclosure_digest: String,
}

#[derive(Serialize)]
struct FrameDocument<'a> {
    frame_id: &'a str,
    session_id: &'a str,
    branch_head_id: &'a str,
    user_turn_id: &'a str,
    messages: Vec<FrameMessageDocument<'a>>,
    attachment_refs: Vec<&'a str>,
}

#[derive(Serialize)]
struct FrameMessageDocument<'a> {
    event_id: &'a str,
    role: &'a str,
    content: &'a str,
    blob_refs: &'a [String],
}

#[derive(Serialize)]
struct ComponentRevisionDocument<'a> {
    slot_id: &'a str,
    slot_kind: &'static str,
    version_id: &'a str,
    entity_version: u64,
}

#[derive(Serialize)]
struct ExecutionPlanDocument<'a> {
    steps: [&'static str; 2],
    context_budget: &'a str,
    streaming_required: bool,
    tool_calling_mode: &'static str,
}

#[derive(Serialize)]
struct ModelInputDocument<'a> {
    messages: Vec<ModelInputMessageDocument<'a>>,
}

#[derive(Serialize)]
struct ModelInputMessageDocument<'a> {
    role: &'static str,
    content: &'a str,
    blob_refs: &'a [String],
    source_segment_id: &'a str,
}

pub(crate) fn derive_authoritative_preparation(
    request: &StartRunRequest,
    frame: &ConversationRunFrame,
    sources: &HostSlotPreparationSources,
) -> RunSnapshotResult<AuthoritativePreparationInput> {
    if frame.frame_ref() != request.conversation_run_frame_ref() {
        return Err(RunSnapshotError::new(
            "preparation.frame_reference_mismatch",
            "resolved conversation frame does not match the start request reference",
        ));
    }
    let frame_ref = frame.frame_ref();
    let frame_document = FrameDocument {
        frame_id: frame_ref.frame_id().as_str(),
        session_id: frame_ref.session_id().0.as_str(),
        branch_head_id: frame_ref.branch_head_id().0.as_str(),
        user_turn_id: frame_ref.user_turn_id().0.as_str(),
        messages: frame
            .messages()
            .iter()
            .map(|message| FrameMessageDocument {
                event_id: message.event_id().0.as_str(),
                role: message.role(),
                content: message.content(),
                blob_refs: message.blob_refs(),
            })
            .collect(),
        attachment_refs: frame
            .attachment_refs()
            .iter()
            .map(|attachment| attachment.as_str())
            .collect(),
    };
    let conversation_frame_digest = canonical_digest("conversation-frame:v1", &frame_document)?;
    let requirements_hash = canonical_digest("agent-requirements:v1", &sources.requirements)?;
    let execution_plan_digest = canonical_digest(
        "execution-plan:v1",
        &ExecutionPlanDocument {
            steps: ["context.assemble", "inference.generate"],
            context_budget: sources.requirements.context_budget(),
            streaming_required: sources.requirements.streaming_required(),
            tool_calling_mode: match sources.requirements.tool_calling_mode() {
                crate::llm_contracts::LLMToolCallingMode::Disabled => "disabled",
                crate::llm_contracts::LLMToolCallingMode::Allowed => "allowed",
                crate::llm_contracts::LLMToolCallingMode::Required => "required",
            },
        },
    )?;
    let tool_schema_digest = canonical_digest("tool-schema:v1", &sources.tool_schema_sources)?;
    let tool_schema_json = String::from_utf8(
        CanonicalDigestV1::canonicalize(&sources.tool_schema_sources)
            .map_err(|error| RunSnapshotError::new(error.code(), error.to_string()))?,
    )
    .map_err(|error| RunSnapshotError::new("preparation.tool_schema_invalid", error.to_string()))?;
    let model_input = ExecutionContextInputAssembler::new(None)
        .assemble_initial(frame)
        .map_err(|error| RunSnapshotError::new(error.code(), error.to_string()))?;
    let model_input_document = ModelInputDocument {
        messages: model_input
            .messages()
            .iter()
            .map(|message| ModelInputMessageDocument {
                role: match message.role() {
                    ModelInputRole::System => "system",
                    ModelInputRole::User => "user",
                    ModelInputRole::Assistant => "assistant",
                    ModelInputRole::Tool => "tool",
                    ModelInputRole::Summary => "summary",
                },
                content: message.content(),
                blob_refs: message.blob_refs(),
                source_segment_id: message.source_segment_id(),
            })
            .collect(),
    };
    let canonical_model_input = CanonicalDigestV1::canonicalize(&model_input_document)
        .map_err(|error| RunSnapshotError::new(error.code(), error.to_string()))?;
    let model_input_digest = canonical_digest("agent-input:v1", &model_input_document)?;
    let model_input_id = format!("frozen-input:{model_input_digest}");
    let mut source_revisions = vec![
        HostSourceRevision {
            source_id: format!("agent-profile:{}", request.agent_profile_id().as_str()),
            revision: request.profile_revision_id().as_u64().to_string(),
            digest: requirements_hash.clone(),
        },
        HostSourceRevision {
            source_id: format!("conversation-frame:{}", frame_ref.frame_id().as_str()),
            revision: frame_ref.user_turn_id().0.clone(),
            digest: conversation_frame_digest.clone(),
        },
    ];
    for component in &sources.component_versions {
        let document = ComponentRevisionDocument {
            slot_id: component.slot_id().as_str(),
            slot_kind: slot_kind(component.slot_kind()),
            version_id: component.version_id().as_str(),
            entity_version: component.entity_version().as_u64(),
        };
        source_revisions.push(HostSourceRevision {
            source_id: format!("component:{}", component.slot_id().as_str()),
            revision: component.entity_version().as_u64().to_string(),
            digest: canonical_digest("source-revisions:v1", &document)?,
        });
    }
    let source_revisions_digest = canonical_digest("source-revisions:v1", &source_revisions)?;
    let attachment_ids: BTreeSet<_> = frame
        .attachment_refs()
        .iter()
        .map(|attachment| attachment.as_str().to_string())
        .chain(
            frame
                .messages()
                .iter()
                .flat_map(|message| message.blob_refs().iter().cloned()),
        )
        .collect();
    let attachments = attachment_ids
        .iter()
        .map(|attachment_id| {
            #[derive(Serialize)]
            struct AttachmentRevision<'a> {
                attachment_id: &'a str,
                revision: &'static str,
            }
            Ok(HostAttachmentReference {
                attachment_id: attachment_id.clone(),
                revision: "1".into(),
                modality: "binary".into(),
                media_type: "application/octet-stream".into(),
                content_digest: canonical_digest(
                    "source-revisions:v1",
                    &AttachmentRevision {
                        attachment_id,
                        revision: "1",
                    },
                )?,
            })
        })
        .collect::<RunSnapshotResult<Vec<_>>>()?;
    let has_attachments = frame
        .messages()
        .iter()
        .any(|message| !message.blob_refs().is_empty())
        || !frame.attachment_refs().is_empty();
    let mut data_classes = vec!["text"];
    if has_attachments {
        data_classes.push("attachment");
    }
    let semantic_messages: Vec<_> =
        model_input
            .messages()
            .iter()
            .map(|message| {
                let mut content = vec![HostSemanticContent {
                    kind: "text".into(),
                    text: Some(message.content().to_string()),
                    modality: None,
                    attachment_id: None,
                    media_type: None,
                }];
                content.extend(message.blob_refs().iter().map(|attachment_id| {
                    HostSemanticContent {
                        kind: "attachment".into(),
                        text: None,
                        modality: Some("binary".into()),
                        attachment_id: Some(attachment_id.clone()),
                        media_type: Some("application/octet-stream".into()),
                    }
                }));
                HostSemanticMessage {
                    role: match message.role() {
                        ModelInputRole::System => "system",
                        ModelInputRole::User => "user",
                        ModelInputRole::Assistant => "assistant",
                        ModelInputRole::Tool => "tool",
                        ModelInputRole::Summary => "summary",
                    }
                    .into(),
                    content,
                }
            })
            .collect();
    let payload = HostCommandPayload {
        schema_version: "1".into(),
        model_input_id: model_input_id.clone(),
        messages: semantic_messages.clone(),
        tool_schema_json,
        tool_schema_digest: tool_schema_digest.clone(),
        source_revisions,
        source_revisions_digest: source_revisions_digest.clone(),
        attachments,
        semantic_history: semantic_messages,
        tool_results: Vec::new(),
    };
    let payload_digest = payload
        .expected_digest()
        .map_err(|error| RunSnapshotError::new(error.code(), error.to_string()))?;
    let disclosure = GenerationDisclosureDocument {
        schema_version: "1".into(),
        generation_turn_id: format!("generation-turn:{model_input_digest}"),
        content_digest: payload_digest.clone(),
        source_revision_digest: source_revisions_digest.clone(),
        data_classes: data_classes.iter().map(ToString::to_string).collect(),
        highest_sensitivity: "private".into(),
        safe_display_summary: SafeDisplaySummaryDocument {
            source_kinds: vec!["conversation".into(), "agent_configuration".into()],
            added_item_counts: data_classes
                .iter()
                .map(|data_class| EgressDataClassCountDocument {
                    data_class: (*data_class).into(),
                    count: if *data_class == "attachment" {
                        attachment_ids.len().to_string()
                    } else {
                        model_input.messages().len().to_string()
                    },
                })
                .collect(),
            approximate_added_size: canonical_model_input.len().to_string(),
            triggering_tool_display_keys: Vec::new(),
        },
    };
    let initial_disclosure_digest = disclosure
        .expected_digest()
        .map_err(|error| RunSnapshotError::new(error.code(), error.to_string()))?;
    Ok(AuthoritativePreparationInput {
        binding: PreparationBinding::new(
            request.agent_profile_id().as_str(),
            request.profile_revision_id().as_u64(),
            conversation_frame_digest,
            execution_plan_digest,
            requirements_hash,
            tool_schema_digest,
            model_input_id,
            model_input_digest,
            source_revisions_digest,
            initial_disclosure_digest.clone(),
        )
        .with_requirements(sources.requirements.clone())
        .with_disclosure_public_fields(data_classes, "private"),
        frozen_turn: FrozenGenerationTurn {
            start_request: request.clone(),
            sources: sources.clone(),
            canonical_model_input,
            payload,
            payload_digest,
            disclosure,
            disclosure_digest: initial_disclosure_digest,
        },
    })
}

fn canonical_digest<T: Serialize>(domain: &str, value: &T) -> RunSnapshotResult<String> {
    CanonicalDigestV1::digest(domain, value)
        .map(|digest| digest.as_str().to_string())
        .map_err(|error| RunSnapshotError::new(error.code(), error.to_string()))
}

fn slot_kind(kind: AgentSlotKind) -> &'static str {
    match kind {
        AgentSlotKind::Brain => "brain",
        AgentSlotKind::Persona => "persona",
        AgentSlotKind::Instruction => "instruction",
        AgentSlotKind::Model => "model",
        AgentSlotKind::Toolset => "toolset",
        AgentSlotKind::Memory => "memory",
        AgentSlotKind::Voice => "voice",
    }
}
