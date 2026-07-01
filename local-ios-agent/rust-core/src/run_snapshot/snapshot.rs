use crate::run_snapshot::{ResolvedComponentBinding, ResolvedModelBinding, TrustedHostRunState};
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
    trusted_host_state: TrustedHostRunState,
    created_at_millis: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunSnapshotPreview {
    request: StartRunRequest,
    snapshot: ResolvedRunSnapshot,
}

impl RunSnapshotId {
    pub fn new(value: u64) -> Self {
        Self(value)
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
        trusted_host_state: TrustedHostRunState,
        created_at_millis: u64,
    ) -> Self {
        Self {
            snapshot_id,
            agent_profile_id: request.agent_profile_id().clone(),
            user_intent: request.user_intent().clone(),
            profile_version,
            component_versions,
            model_binding,
            trusted_host_state,
            created_at_millis,
        }
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

    pub fn trusted_host_state(&self) -> &TrustedHostRunState {
        &self.trusted_host_state
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
