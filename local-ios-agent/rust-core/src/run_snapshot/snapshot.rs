use crate::run_snapshot::{
    ResolvedComponentBinding, ResolvedMemoryBinding, ResolvedModelBinding, ResolvedToolBinding,
    ResolvedVoiceBinding, TrustedHostRunState,
};
use crate::user_customization::{AgentProfileId, AgentProfileVersion};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct RunSnapshotId(u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunUserIntent(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartRunRequest {
    agent_profile_id: AgentProfileId,
    user_intent: RunUserIntent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotResolveInput {
    request: StartRunRequest,
    trusted_host_state: TrustedHostRunState,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedRunSnapshot {
    snapshot_id: RunSnapshotId,
    agent_profile_id: AgentProfileId,
    user_intent: RunUserIntent,
    profile_version: AgentProfileVersion,
    component_versions: Vec<ResolvedComponentBinding>,
    model_binding: ResolvedModelBinding,
    tool_bindings: Vec<ResolvedToolBinding>,
    memory_binding: Option<ResolvedMemoryBinding>,
    voice_binding: Option<ResolvedVoiceBinding>,
    trusted_host_state: TrustedHostRunState,
    readiness_report: RunSnapshotReadinessReport,
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
    pub fn new(agent_profile_id: impl Into<String>, user_intent: impl Into<String>) -> Self {
        Self {
            agent_profile_id: AgentProfileId::new(agent_profile_id),
            user_intent: RunUserIntent::new(user_intent),
        }
    }

    pub fn agent_profile_id(&self) -> &AgentProfileId {
        &self.agent_profile_id
    }

    pub fn user_intent(&self) -> &RunUserIntent {
        &self.user_intent
    }
}

impl RunSnapshotResolveInput {
    pub(in crate::run_snapshot) fn new(
        request: StartRunRequest,
        trusted_host_state: TrustedHostRunState,
    ) -> Self {
        Self {
            request,
            trusted_host_state,
        }
    }

    pub fn request(&self) -> &StartRunRequest {
        &self.request
    }

    pub fn trusted_host_state(&self) -> &TrustedHostRunState {
        &self.trusted_host_state
    }

    pub(in crate::run_snapshot) fn into_parts(self) -> (StartRunRequest, TrustedHostRunState) {
        (self.request, self.trusted_host_state)
    }
}

impl ResolvedRunSnapshot {
    pub(crate) fn new(
        snapshot_id: RunSnapshotId,
        request: StartRunRequest,
        profile_version: AgentProfileVersion,
        component_versions: Vec<ResolvedComponentBinding>,
        model_binding: ResolvedModelBinding,
        tool_bindings: Vec<ResolvedToolBinding>,
        memory_binding: Option<ResolvedMemoryBinding>,
        voice_binding: Option<ResolvedVoiceBinding>,
        trusted_host_state: TrustedHostRunState,
        readiness_report: RunSnapshotReadinessReport,
        created_at_millis: u64,
    ) -> Self {
        Self {
            snapshot_id,
            agent_profile_id: request.agent_profile_id().clone(),
            user_intent: request.user_intent().clone(),
            profile_version,
            component_versions,
            model_binding,
            tool_bindings,
            memory_binding,
            voice_binding,
            trusted_host_state,
            readiness_report,
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

    pub fn model_binding(&self) -> &ResolvedModelBinding {
        &self.model_binding
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

    pub fn trusted_host_state(&self) -> &TrustedHostRunState {
        &self.trusted_host_state
    }

    pub fn readiness_report(&self) -> &RunSnapshotReadinessReport {
        &self.readiness_report
    }

    pub fn created_at_millis(&self) -> u64 {
        self.created_at_millis
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
