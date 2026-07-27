use std::fmt;

use crate::conversation::{ConversationFrameId, ConversationRunFrameRef};
use crate::core::{EntryId, SessionId};
use crate::llm_contracts::{AgentLLMRequirements, HostAttestation, HostAttestationV1Document};
use crate::run_snapshot::{
    OpaqueHostBindingCrossLink, ResolvedComponentBinding, ResolvedHostSlotBinding,
    ResolvedMemoryBinding, ResolvedToolBinding, ResolvedVoiceBinding,
};
use crate::user_customization::{AgentProfileId, AgentProfileVersion, AgentSlotId, AgentSlotKind};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RunSnapshotId(u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunUserIntent(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartRunRequest {
    agent_profile_id: AgentProfileId,
    profile_revision_id: AgentProfileVersion,
    user_intent: RunUserIntent,
    conversation_run_frame_ref: ConversationRunFrameRef,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotResolveInput {
    request: StartRunRequest,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedRunSnapshot {
    snapshot_id: RunSnapshotId,
    agent_profile_id: AgentProfileId,
    user_intent: RunUserIntent,
    profile_version: AgentProfileVersion,
    component_versions: Vec<ResolvedComponentBinding>,
    llm_binding: ResolvedHostSlotBinding,
    tool_bindings: Vec<ResolvedToolBinding>,
    memory_binding: Option<ResolvedMemoryBinding>,
    voice_binding: Option<ResolvedVoiceBinding>,
    readiness_report: RunSnapshotReadinessReport,
    conversation_run_frame_ref: ConversationRunFrameRef,
    created_at_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotPreview {
    request: StartRunRequest,
    snapshot: ResolvedRunSnapshot,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotReadinessReport {
    issues: Vec<RunSnapshotReadinessIssue>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotReadinessIssue {
    code: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedResolvedRunSnapshotV2 {
    schema_version: u32,
    snapshot_id: u64,
    agent_profile_id: String,
    user_intent: String,
    profile_version: u64,
    component_versions: Vec<PersistedComponentBinding>,
    llm_binding: PersistedResolvedHostSlotBinding,
    tool_bindings: Vec<PersistedToolBinding>,
    memory_binding: Option<PersistedSlotComponentBinding>,
    voice_binding: Option<PersistedSlotComponentBinding>,
    readiness_issues: Vec<PersistedReadinessIssue>,
    conversation_frame: PersistedConversationFrameRef,
    created_at_millis: u64,
    host_attestation: Option<PersistedHostAttestation>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedResolvedHostSlotBinding {
    requirements: AgentLLMRequirements,
    requirements_hash: String,
    binding_id: String,
    binding_revision: u64,
    binding_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedComponentBinding {
    slot_id: String,
    slot_kind: String,
    version_id: String,
    entity_version: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedToolBinding {
    slot_id: String,
    component: PersistedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedSlotComponentBinding {
    slot_id: String,
    component: PersistedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedReadinessIssue {
    code: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedConversationFrameRef {
    frame_id: String,
    session_id: String,
    branch_head_id: String,
    user_turn_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PersistedHostAttestation {
    document: HostAttestationV1Document,
    egress_attestation_digest: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PersistedRunSnapshotError {
    code: &'static str,
    message: String,
}

impl PersistedRunSnapshotError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        self.code
    }
}

impl fmt::Display for PersistedRunSnapshotError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for PersistedRunSnapshotError {}

impl RunSnapshotId {
    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub(in crate::run_snapshot) fn unpersisted() -> Self {
        Self(0)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl RunUserIntent {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl StartRunRequest {
    pub fn new(
        agent_profile_id: impl Into<String>,
        profile_revision_id: AgentProfileVersion,
        user_intent: impl Into<String>,
        conversation_run_frame_ref: ConversationRunFrameRef,
    ) -> Self {
        Self {
            agent_profile_id: AgentProfileId::new(agent_profile_id),
            profile_revision_id,
            user_intent: RunUserIntent::new(user_intent),
            conversation_run_frame_ref,
        }
    }

    pub fn agent_profile_id(&self) -> &AgentProfileId {
        &self.agent_profile_id
    }

    pub fn profile_revision_id(&self) -> AgentProfileVersion {
        self.profile_revision_id
    }

    pub fn user_intent(&self) -> &RunUserIntent {
        &self.user_intent
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }
}

impl RunSnapshotResolveInput {
    pub(in crate::run_snapshot) fn new(request: StartRunRequest) -> Self {
        Self { request }
    }

    pub fn request(&self) -> &StartRunRequest {
        &self.request
    }

    pub(in crate::run_snapshot) fn into_request(self) -> StartRunRequest {
        self.request
    }
}

impl ResolvedRunSnapshot {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new_host_slot_v2(
        request: StartRunRequest,
        profile_version: AgentProfileVersion,
        component_versions: Vec<ResolvedComponentBinding>,
        requirements: crate::llm_contracts::AgentLLMRequirements,
        requirements_hash: impl Into<String>,
        host_cross_link: OpaqueHostBindingCrossLink,
        tool_bindings: Vec<ResolvedToolBinding>,
        memory_binding: Option<ResolvedMemoryBinding>,
        voice_binding: Option<ResolvedVoiceBinding>,
        created_at_millis: u64,
    ) -> Self {
        Self {
            snapshot_id: RunSnapshotId::unpersisted(),
            agent_profile_id: request.agent_profile_id().clone(),
            user_intent: request.user_intent().clone(),
            profile_version,
            component_versions,
            llm_binding: ResolvedHostSlotBinding::new(
                requirements,
                requirements_hash,
                host_cross_link,
            ),
            tool_bindings,
            memory_binding,
            voice_binding,
            readiness_report: RunSnapshotReadinessReport::ready(),
            conversation_run_frame_ref: request.conversation_run_frame_ref().clone(),
            created_at_millis,
        }
    }

    pub(in crate::run_snapshot) fn with_snapshot_id(mut self, snapshot_id: RunSnapshotId) -> Self {
        self.snapshot_id = snapshot_id;
        self
    }

    pub fn snapshot_id(&self) -> RunSnapshotId {
        self.snapshot_id
    }

    pub fn agent_profile_id(&self) -> &AgentProfileId {
        &self.agent_profile_id
    }

    pub fn user_intent(&self) -> &RunUserIntent {
        &self.user_intent
    }

    pub fn profile_version(&self) -> AgentProfileVersion {
        self.profile_version
    }

    pub fn component_versions(&self) -> &[ResolvedComponentBinding] {
        &self.component_versions
    }

    pub fn llm_binding(&self) -> &ResolvedHostSlotBinding {
        &self.llm_binding
    }

    pub fn host_slot_binding(&self) -> &ResolvedHostSlotBinding {
        &self.llm_binding
    }

    pub fn tool_bindings(&self) -> &[ResolvedToolBinding] {
        &self.tool_bindings
    }

    pub fn memory_binding(&self) -> Option<&ResolvedMemoryBinding> {
        self.memory_binding.as_ref()
    }

    pub fn voice_binding(&self) -> Option<&ResolvedVoiceBinding> {
        self.voice_binding.as_ref()
    }

    pub fn readiness_report(&self) -> &RunSnapshotReadinessReport {
        &self.readiness_report
    }

    pub fn conversation_run_frame_ref(&self) -> &ConversationRunFrameRef {
        &self.conversation_run_frame_ref
    }

    pub fn created_at_millis(&self) -> u64 {
        self.created_at_millis
    }

    pub(crate) fn host_v2_json(
        &self,
        run_id: &str,
        swift_snapshot_id: &str,
        attestation: &HostAttestation,
    ) -> Result<String, PersistedRunSnapshotError> {
        if attestation.document().proposed_run_id() != run_id
            || attestation.document().swift_snapshot_id() != swift_snapshot_id
        {
            return Err(PersistedRunSnapshotError::new(
                "snapshot.host_identity_mismatch",
                "host snapshot binding, run ID, or Swift snapshot ID does not match attestation",
            ));
        }
        let persisted =
            PersistedResolvedRunSnapshotV2::try_from(self)?.with_host_attestation(attestation);
        serde_json::to_string(&persisted).map_err(|error| {
            PersistedRunSnapshotError::new(
                "snapshot.serialization_failed",
                format!("persisted run snapshot serialization failed: {error}"),
            )
        })
    }
}

impl TryFrom<&ResolvedRunSnapshot> for PersistedResolvedRunSnapshotV2 {
    type Error = PersistedRunSnapshotError;

    fn try_from(snapshot: &ResolvedRunSnapshot) -> Result<Self, Self::Error> {
        let binding = snapshot.llm_binding();
        let llm_binding = PersistedResolvedHostSlotBinding {
            requirements: binding.requirements().clone(),
            requirements_hash: binding.requirements_hash().to_string(),
            binding_id: binding.host_cross_link().binding_id().to_string(),
            binding_revision: binding.host_cross_link().binding_revision(),
            binding_hash: binding.host_cross_link().binding_hash().to_string(),
        };
        Ok(Self {
            schema_version: 2,
            snapshot_id: snapshot.snapshot_id().as_u64(),
            agent_profile_id: snapshot.agent_profile_id().as_str().to_string(),
            user_intent: snapshot.user_intent().as_str().to_string(),
            profile_version: snapshot.profile_version().as_u64(),
            component_versions: snapshot
                .component_versions()
                .iter()
                .map(persist_component)
                .collect(),
            llm_binding,
            tool_bindings: snapshot
                .tool_bindings()
                .iter()
                .map(|tool| PersistedToolBinding {
                    slot_id: tool.slot_id().as_str().to_string(),
                    component: persist_component(tool.component_version()),
                })
                .collect(),
            memory_binding: snapshot
                .memory_binding()
                .map(|memory| PersistedSlotComponentBinding {
                    slot_id: memory.slot_id().as_str().to_string(),
                    component: persist_component(memory.component_version()),
                }),
            voice_binding: snapshot
                .voice_binding()
                .map(|voice| PersistedSlotComponentBinding {
                    slot_id: voice.slot_id().as_str().to_string(),
                    component: persist_component(voice.component_version()),
                }),
            readiness_issues: snapshot
                .readiness_report()
                .issues()
                .iter()
                .map(|issue| PersistedReadinessIssue {
                    code: issue.code().to_string(),
                    message: issue.message().to_string(),
                })
                .collect(),
            conversation_frame: PersistedConversationFrameRef {
                frame_id: snapshot
                    .conversation_run_frame_ref()
                    .frame_id()
                    .as_str()
                    .to_string(),
                session_id: snapshot.conversation_run_frame_ref().session_id().0.clone(),
                branch_head_id: snapshot
                    .conversation_run_frame_ref()
                    .branch_head_id()
                    .0
                    .clone(),
                user_turn_id: snapshot
                    .conversation_run_frame_ref()
                    .user_turn_id()
                    .0
                    .clone(),
            },
            created_at_millis: snapshot.created_at_millis(),
            host_attestation: None,
        })
    }
}

impl TryFrom<PersistedResolvedRunSnapshotV2> for ResolvedRunSnapshot {
    type Error = PersistedRunSnapshotError;

    fn try_from(persisted: PersistedResolvedRunSnapshotV2) -> Result<Self, Self::Error> {
        if persisted.schema_version != 2 {
            return Err(PersistedRunSnapshotError::new(
                "snapshot.schema_version_unsupported",
                format!(
                    "persisted run snapshot schema {} is unsupported",
                    persisted.schema_version
                ),
            ));
        }
        let binding = persisted.llm_binding;
        let llm_binding = ResolvedHostSlotBinding::new(
            binding.requirements,
            binding.requirements_hash,
            OpaqueHostBindingCrossLink::new(
                binding.binding_id,
                binding.binding_revision,
                binding.binding_hash,
            ),
        );
        Ok(Self {
            snapshot_id: RunSnapshotId::new(persisted.snapshot_id),
            agent_profile_id: AgentProfileId::new(persisted.agent_profile_id),
            user_intent: RunUserIntent::new(persisted.user_intent),
            profile_version: AgentProfileVersion::new(persisted.profile_version),
            component_versions: persisted
                .component_versions
                .into_iter()
                .map(resolve_component)
                .collect::<Result<_, _>>()?,
            llm_binding,
            tool_bindings: persisted
                .tool_bindings
                .into_iter()
                .map(|tool| {
                    Ok(ResolvedToolBinding::new(
                        AgentSlotId::new(tool.slot_id),
                        resolve_component(tool.component)?,
                    ))
                })
                .collect::<Result<_, PersistedRunSnapshotError>>()?,
            memory_binding: persisted
                .memory_binding
                .map(|memory| {
                    Ok(ResolvedMemoryBinding::new(
                        AgentSlotId::new(memory.slot_id),
                        resolve_component(memory.component)?,
                    ))
                })
                .transpose()?,
            voice_binding: persisted
                .voice_binding
                .map(|voice| {
                    Ok(ResolvedVoiceBinding::new(
                        AgentSlotId::new(voice.slot_id),
                        resolve_component(voice.component)?,
                    ))
                })
                .transpose()?,
            readiness_report: RunSnapshotReadinessReport {
                issues: persisted
                    .readiness_issues
                    .into_iter()
                    .map(|issue| RunSnapshotReadinessIssue {
                        code: issue.code,
                        message: issue.message,
                    })
                    .collect(),
            },
            conversation_run_frame_ref: ConversationRunFrameRef::new(
                ConversationFrameId::new(persisted.conversation_frame.frame_id),
                SessionId(persisted.conversation_frame.session_id),
                EntryId(persisted.conversation_frame.branch_head_id),
                EntryId(persisted.conversation_frame.user_turn_id),
            ),
            created_at_millis: persisted.created_at_millis,
        })
    }
}

impl PersistedResolvedRunSnapshotV2 {
    fn with_host_attestation(mut self, attestation: &HostAttestation) -> Self {
        self.host_attestation = Some(PersistedHostAttestation {
            document: attestation.document().clone(),
            egress_attestation_digest: attestation.egress_attestation_digest().to_string(),
        });
        self
    }
}

fn persist_component(component: &ResolvedComponentBinding) -> PersistedComponentBinding {
    PersistedComponentBinding {
        slot_id: component.slot_id().as_str().to_string(),
        slot_kind: slot_kind_name(component.slot_kind()).to_string(),
        version_id: component.version_id().as_str().to_string(),
        entity_version: component.entity_version().as_u64(),
    }
}

fn resolve_component(
    component: PersistedComponentBinding,
) -> Result<ResolvedComponentBinding, PersistedRunSnapshotError> {
    Ok(ResolvedComponentBinding::new(
        AgentSlotId::new(component.slot_id),
        parse_slot_kind(&component.slot_kind)?,
        component.version_id,
        component.entity_version,
    ))
}

fn slot_kind_name(kind: AgentSlotKind) -> &'static str {
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

fn parse_slot_kind(value: &str) -> Result<AgentSlotKind, PersistedRunSnapshotError> {
    match value {
        "brain" => Ok(AgentSlotKind::Brain),
        "persona" => Ok(AgentSlotKind::Persona),
        "instruction" => Ok(AgentSlotKind::Instruction),
        "model" => Ok(AgentSlotKind::Model),
        "toolset" => Ok(AgentSlotKind::Toolset),
        "memory" => Ok(AgentSlotKind::Memory),
        "voice" => Ok(AgentSlotKind::Voice),
        other => Err(PersistedRunSnapshotError::new(
            "snapshot.slot_kind_invalid",
            format!("persisted slot kind {other:?} is invalid"),
        )),
    }
}

impl RunSnapshotPreview {
    pub(crate) fn new(request: StartRunRequest, snapshot: ResolvedRunSnapshot) -> Self {
        Self { request, snapshot }
    }

    pub(crate) fn request(&self) -> &StartRunRequest {
        &self.request
    }

    pub fn snapshot(&self) -> &ResolvedRunSnapshot {
        &self.snapshot
    }
}

impl RunSnapshotReadinessReport {
    pub(in crate::run_snapshot) fn ready() -> Self {
        Self { issues: Vec::new() }
    }

    pub(in crate::run_snapshot) fn with_issue(mut self, issue: RunSnapshotReadinessIssue) -> Self {
        self.issues.push(issue);
        self
    }

    pub fn is_ready(&self) -> bool {
        self.issues.is_empty()
    }

    pub fn has_issue(&self, code: &str) -> bool {
        self.issues.iter().any(|issue| issue.code() == code)
    }

    pub fn issues(&self) -> &[RunSnapshotReadinessIssue] {
        &self.issues
    }
}

impl RunSnapshotReadinessIssue {
    pub(in crate::run_snapshot) fn new(
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}
