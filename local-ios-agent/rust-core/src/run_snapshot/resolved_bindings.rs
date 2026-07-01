use std::collections::BTreeMap;

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

impl SnapshotModelId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TrustedHostRunState {
    pub(in crate::run_snapshot) fn capture(
        permission_state: PermissionState,
        local_bindings: &AgentProfileLocalBindings,
    ) -> Self {
        let local_bindings = LocalBindingState::from_profile(local_bindings);
        let credential_availability = CredentialAvailability::from_local_bindings(&local_bindings);
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
    fn from_profile(local_bindings: &AgentProfileLocalBindings) -> Self {
        Self {
            credential_refs: local_bindings.credential_refs().clone(),
        }
    }

    pub fn credential_ref_for(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
    }
}

impl CredentialAvailability {
    fn from_local_bindings(local_bindings: &LocalBindingState) -> Self {
        Self {
            credential_refs: local_bindings.credential_refs.clone(),
        }
    }

    pub fn credential_ref_for(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
    }
}
