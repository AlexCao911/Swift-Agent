use serde::Serialize;

use crate::canonical_digest::CanonicalDigestV1;
use crate::context::ModelInputRole;
use crate::conversation::ConversationRunFrame;
use crate::execution::ExecutionContextInputAssembler;
use crate::llm_contracts::PreparationBinding;
use crate::run_snapshot::{RunSnapshotError, RunSnapshotResult, StartRunRequest};
use crate::user_customization::AgentSlotKind;

use super::resolver::HostSlotPreparationSources;

pub(crate) struct AuthoritativePreparationInput {
    pub(crate) binding: PreparationBinding,
    pub(crate) canonical_model_input: Vec<u8>,
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
struct SourceRevisionsDocument<'a> {
    agent_profile_id: &'a str,
    agent_profile_revision: u64,
    frame_id: &'a str,
    components: Vec<ComponentRevisionDocument<'a>>,
    attachment_refs: Vec<&'a str>,
}

#[derive(Serialize)]
struct ExecutionPlanDocument<'a> {
    steps: [&'static str; 2],
    context_budget: &'a str,
    streaming_required: bool,
    tool_calling_mode: &'static str,
}

#[derive(Serialize)]
struct ToolSchemaDocument<'a> {
    slot_id: &'a str,
    component_version: &'a str,
    entity_version: u64,
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

#[derive(Serialize)]
struct DisclosureDocument<'a> {
    model_input_digest: &'a str,
    data_classes: Vec<&'static str>,
    highest_sensitivity: &'static str,
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
    let tool_document: Vec<_> = sources
        .tool_bindings
        .iter()
        .map(|tool| ToolSchemaDocument {
            slot_id: tool.slot_id().as_str(),
            component_version: tool.component_version().version_id().as_str(),
            entity_version: tool.component_version().entity_version().as_u64(),
        })
        .collect();
    let tool_schema_digest = canonical_digest("tool-schema:v1", &tool_document)?;
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
    let source_revisions_digest = canonical_digest(
        "source-revisions:v1",
        &SourceRevisionsDocument {
            agent_profile_id: request.agent_profile_id().as_str(),
            agent_profile_revision: request.profile_revision_id().as_u64(),
            frame_id: frame_ref.frame_id().as_str(),
            components: sources
                .component_versions
                .iter()
                .map(|component| ComponentRevisionDocument {
                    slot_id: component.slot_id().as_str(),
                    slot_kind: slot_kind(component.slot_kind()),
                    version_id: component.version_id().as_str(),
                    entity_version: component.entity_version().as_u64(),
                })
                .collect(),
            attachment_refs: frame
                .attachment_refs()
                .iter()
                .map(|attachment| attachment.as_str())
                .collect(),
        },
    )?;
    let has_attachments = frame
        .messages()
        .iter()
        .any(|message| !message.blob_refs().is_empty())
        || !frame.attachment_refs().is_empty();
    let mut data_classes = vec!["text"];
    if has_attachments {
        data_classes.push("attachment");
    }
    let initial_disclosure_digest = canonical_digest(
        "generation-disclosure:v1",
        &DisclosureDocument {
            model_input_digest: &model_input_digest,
            data_classes,
            highest_sensitivity: "private",
        },
    )?;
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
            initial_disclosure_digest,
        ),
        canonical_model_input,
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
