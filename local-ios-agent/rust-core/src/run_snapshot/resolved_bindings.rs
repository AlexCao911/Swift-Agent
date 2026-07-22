use std::collections::BTreeMap;

use crate::llm_contracts::AgentLLMRequirements;
use crate::model::ModelSelection;
use crate::security::PermissionState;
use crate::user_customization::{AgentProfileLocalBindings, AgentSlotId, AgentSlotKind};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedComponentBinding {
    slot_id: AgentSlotId,
    slot_kind: AgentSlotKind,
    version_id: SnapshotComponentVersionId,
    entity_version: SnapshotEntityVersion,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotComponentVersionId(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SnapshotEntityVersion(u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedModelBinding {
    binding_id: String,
    provider_account_id: String,
    provider_id: String,
    model_id: SnapshotModelId,
    catalog_version: SnapshotEntityVersion,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ResolvedLLMBinding {
    LegacyV1 {
        model: ResolvedModelBinding,
        trusted_host_state: TrustedHostRunState,
    },
    HostSlotV2(ResolvedHostSlotBinding),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedHostSlotBinding {
    requirements: AgentLLMRequirements,
    requirements_hash: String,
    host_cross_link: OpaqueHostBindingCrossLink,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OpaqueHostBindingCrossLink {
    binding_id: String,
    binding_revision: u64,
    binding_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedToolBinding {
    slot_id: AgentSlotId,
    component_version: ResolvedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedMemoryBinding {
    slot_id: AgentSlotId,
    component_version: ResolvedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedVoiceBinding {
    slot_id: AgentSlotId,
    component_version: ResolvedComponentBinding,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotModelId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TrustedHostRunState {
    permission_state: PermissionState,
    local_bindings: LocalBindingState,
    credential_availability: CredentialAvailability,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LocalBindingState {
    credential_refs: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CredentialAvailability {
    credential_refs: BTreeMap<String, String>,
}

impl ResolvedComponentBinding {
    pub(crate) fn new(
        slot_id: AgentSlotId,
        slot_kind: AgentSlotKind,
        version_id: impl Into<String>,
        entity_version: u64,
    ) -> Self {
        Self {
            slot_id,
            slot_kind,
            version_id: SnapshotComponentVersionId(version_id.into()),
            entity_version: SnapshotEntityVersion(entity_version),
        }
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn slot_kind(&self) -> AgentSlotKind {
        self.slot_kind
    }

    pub fn version_id(&self) -> &SnapshotComponentVersionId {
        &self.version_id
    }

    pub fn entity_version(&self) -> SnapshotEntityVersion {
        self.entity_version
    }
}

impl SnapshotComponentVersionId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl SnapshotEntityVersion {
    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl ResolvedModelBinding {
    pub(crate) fn from_selection(selection: &ModelSelection) -> Self {
        Self {
            binding_id: selection.binding_id().as_str().to_string(),
            provider_account_id: selection.provider_account_id().to_string(),
            provider_id: selection.provider_id().to_string(),
            model_id: SnapshotModelId(selection.model_id().to_string()),
            catalog_version: SnapshotEntityVersion(selection.catalog_version().as_u64()),
        }
    }

    pub(in crate::run_snapshot) fn from_persisted(
        binding_id: impl Into<String>,
        provider_account_id: impl Into<String>,
        provider_id: impl Into<String>,
        model_id: impl Into<String>,
        catalog_version: u64,
    ) -> Self {
        Self {
            binding_id: binding_id.into(),
            provider_account_id: provider_account_id.into(),
            provider_id: provider_id.into(),
            model_id: SnapshotModelId(model_id.into()),
            catalog_version: SnapshotEntityVersion(catalog_version),
        }
    }

    pub fn binding_id(&self) -> &str {
        &self.binding_id
    }

    pub fn provider_account_id(&self) -> &str {
        &self.provider_account_id
    }

    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    pub fn model_id(&self) -> &SnapshotModelId {
        &self.model_id
    }

    pub fn catalog_version(&self) -> SnapshotEntityVersion {
        self.catalog_version
    }
}

impl ResolvedLLMBinding {
    pub fn as_host_slot_v2(&self) -> Option<&ResolvedHostSlotBinding> {
        match self {
            Self::HostSlotV2(binding) => Some(binding),
            Self::LegacyV1 { .. } => None,
        }
    }

    pub fn as_legacy_v1(&self) -> Option<(&ResolvedModelBinding, &TrustedHostRunState)> {
        match self {
            Self::LegacyV1 {
                model,
                trusted_host_state,
            } => Some((model, trusted_host_state)),
            Self::HostSlotV2(_) => None,
        }
    }
}

impl ResolvedHostSlotBinding {
    pub(crate) fn new(
        requirements: AgentLLMRequirements,
        requirements_hash: impl Into<String>,
        host_cross_link: OpaqueHostBindingCrossLink,
    ) -> Self {
        Self {
            requirements,
            requirements_hash: requirements_hash.into(),
            host_cross_link,
        }
    }

    pub fn requirements(&self) -> &AgentLLMRequirements {
        &self.requirements
    }

    pub fn requirements_hash(&self) -> &str {
        &self.requirements_hash
    }

    pub fn host_cross_link(&self) -> &OpaqueHostBindingCrossLink {
        &self.host_cross_link
    }
}

impl OpaqueHostBindingCrossLink {
    pub(crate) fn new(
        binding_id: impl Into<String>,
        binding_revision: u64,
        binding_hash: impl Into<String>,
    ) -> Self {
        Self {
            binding_id: binding_id.into(),
            binding_revision,
            binding_hash: binding_hash.into(),
        }
    }

    pub fn binding_id(&self) -> &str {
        &self.binding_id
    }

    pub fn binding_revision(&self) -> u64 {
        self.binding_revision
    }

    pub fn binding_hash(&self) -> &str {
        &self.binding_hash
    }
}

impl SnapshotModelId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TrustedHostRunState {
    pub(in crate::run_snapshot) fn new(
        permission_state: PermissionState,
        local_bindings: LocalBindingState,
        credential_availability: CredentialAvailability,
    ) -> Self {
        Self {
            permission_state,
            local_bindings,
            credential_availability,
        }
    }

    pub fn permission_state(&self) -> &PermissionState {
        &self.permission_state
    }

    pub fn local_bindings(&self) -> &LocalBindingState {
        &self.local_bindings
    }

    pub fn credential_availability(&self) -> &CredentialAvailability {
        &self.credential_availability
    }
}

impl LocalBindingState {
    pub(in crate::run_snapshot) fn from_profile(
        local_bindings: &AgentProfileLocalBindings,
    ) -> Self {
        Self {
            credential_refs: local_bindings.credential_refs().clone(),
        }
    }

    pub(in crate::run_snapshot) fn from_persisted(
        credential_refs: BTreeMap<String, String>,
    ) -> Self {
        Self { credential_refs }
    }

    pub(in crate::run_snapshot) fn persisted_refs(&self) -> BTreeMap<String, String> {
        self.credential_refs.clone()
    }

    pub fn credential_ref_for(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
    }
}

impl CredentialAvailability {
    pub(in crate::run_snapshot) fn with_available_ref(
        mut self,
        binding_key: impl Into<String>,
        credential_ref: impl Into<String>,
    ) -> Self {
        self.credential_refs
            .insert(binding_key.into(), credential_ref.into());
        self
    }

    pub(in crate::run_snapshot) fn from_persisted(
        credential_refs: BTreeMap<String, String>,
    ) -> Self {
        Self { credential_refs }
    }

    pub(in crate::run_snapshot) fn persisted_refs(&self) -> BTreeMap<String, String> {
        self.credential_refs.clone()
    }

    pub fn credential_ref_for(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
    }
}

impl ResolvedToolBinding {
    pub(in crate::run_snapshot) fn new(
        slot_id: AgentSlotId,
        component_version: ResolvedComponentBinding,
    ) -> Self {
        Self {
            slot_id,
            component_version,
        }
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn component_version(&self) -> &ResolvedComponentBinding {
        &self.component_version
    }
}

impl ResolvedMemoryBinding {
    pub(in crate::run_snapshot) fn new(
        slot_id: AgentSlotId,
        component_version: ResolvedComponentBinding,
    ) -> Self {
        Self {
            slot_id,
            component_version,
        }
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn component_version(&self) -> &ResolvedComponentBinding {
        &self.component_version
    }
}

impl ResolvedVoiceBinding {
    pub(in crate::run_snapshot) fn new(
        slot_id: AgentSlotId,
        component_version: ResolvedComponentBinding,
    ) -> Self {
        Self {
            slot_id,
            component_version,
        }
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn component_version(&self) -> &ResolvedComponentBinding {
        &self.component_version
    }
}
