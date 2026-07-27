use crate::llm_contracts::AgentLLMRequirements;
use crate::user_customization::{AgentSlotId, AgentSlotKind};

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
