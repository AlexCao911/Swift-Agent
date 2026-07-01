use std::collections::BTreeMap;

use crate::{
    core::AgentError,
    user_customization::{AgentSlotId, AgentSlotKind, AgentTemplateId, UserComponentVersionId},
};

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct AgentProfileId(String);

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct AgentProfileVersion(u64);

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ComponentSettings {
    values: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentProfileLocalBindings {
    credential_refs: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentBinding {
    slot_id: AgentSlotId,
    slot_kind: AgentSlotKind,
    component_version_id: UserComponentVersionId,
    settings: ComponentSettings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfileDraft {
    id: AgentProfileId,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    local_bindings: AgentProfileLocalBindings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfile {
    id: AgentProfileId,
    version: AgentProfileVersion,
    template_id: AgentTemplateId,
    name: String,
    bindings: Vec<ComponentBinding>,
    local_bindings: AgentProfileLocalBindings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentProfileReference {
    profile_id: AgentProfileId,
    profile_version: Option<AgentProfileVersion>,
}

impl AgentProfileId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl AgentProfileVersion {
    pub fn initial() -> Self {
        Self(1)
    }

    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl ComponentSettings {
    pub fn with_value(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.values.insert(key.into(), value.into());
        self
    }

    pub fn value(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    pub fn values(&self) -> &BTreeMap<String, String> {
        &self.values
    }
}

impl AgentProfileLocalBindings {
    pub fn with_credential_ref(
        mut self,
        binding_key: impl Into<String>,
        credential_ref: impl Into<String>,
    ) -> Self {
        self.credential_refs
            .insert(binding_key.into(), credential_ref.into());
        self
    }

    pub fn credential_ref(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
    }

    pub fn credential_refs(&self) -> &BTreeMap<String, String> {
        &self.credential_refs
    }

    pub fn is_empty(&self) -> bool {
        self.credential_refs.is_empty()
    }
}

impl ComponentBinding {
    pub fn new(
        slot_id: AgentSlotId,
        slot_kind: AgentSlotKind,
        component_version_id: UserComponentVersionId,
        settings: ComponentSettings,
    ) -> Self {
        Self {
            slot_id,
            slot_kind,
            component_version_id,
            settings,
        }
    }

    pub fn persona(slot_id: AgentSlotId, component_version_id: UserComponentVersionId) -> Self {
        Self {
            slot_id,
            slot_kind: AgentSlotKind::Persona,
            component_version_id,
            settings: ComponentSettings::default(),
        }
    }

    pub fn slot_id(&self) -> &AgentSlotId {
        &self.slot_id
    }

    pub fn slot_kind(&self) -> AgentSlotKind {
        self.slot_kind
    }

    pub fn component_version_id(&self) -> UserComponentVersionId {
        self.component_version_id
    }

    pub fn settings(&self) -> &ComponentSettings {
        &self.settings
    }
}

impl AgentProfileDraft {
    pub fn new(id: AgentProfileId, template_id: AgentTemplateId, name: impl Into<String>) -> Self {
        Self {
            id,
            template_id,
            name: name.into(),
            bindings: Vec::new(),
            local_bindings: AgentProfileLocalBindings::default(),
        }
    }

    pub fn bind(mut self, binding: ComponentBinding) -> Self {
        self.bindings.push(binding);
        self
    }

    pub fn with_local_bindings(mut self, local_bindings: AgentProfileLocalBindings) -> Self {
        self.local_bindings = local_bindings;
        self
    }

    pub fn publish(self) -> Result<AgentProfile, AgentError> {
        for binding in &self.bindings {
            if !binding.component_version_id.is_published() {
                return Err(AgentError::Unknown(format!(
                    "agent profile binding must reference published component version: {}",
                    binding.component_version_id.stable_key()
                )));
            }
        }

        Ok(AgentProfile {
            id: self.id,
            version: AgentProfileVersion::initial(),
            template_id: self.template_id,
            name: self.name,
            bindings: self.bindings,
            local_bindings: self.local_bindings,
        })
    }
}

impl AgentProfile {
    pub fn id(&self) -> &AgentProfileId {
        &self.id
    }

    pub fn version(&self) -> AgentProfileVersion {
        self.version
    }

    pub fn template_id(&self) -> &AgentTemplateId {
        &self.template_id
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn bindings(&self) -> &[ComponentBinding] {
        &self.bindings
    }

    pub fn local_bindings(&self) -> &AgentProfileLocalBindings {
        &self.local_bindings
    }

    pub fn binding_for_slot(&self, slot_id: &AgentSlotId) -> Option<&ComponentBinding> {
        self.bindings
            .iter()
            .find(|binding| binding.slot_id() == slot_id)
    }

    pub fn bindings_for_kind(&self, slot_kind: AgentSlotKind) -> Vec<&ComponentBinding> {
        self.bindings
            .iter()
            .filter(|binding| binding.slot_kind() == slot_kind)
            .collect()
    }

    pub fn reference(&self) -> AgentProfileReference {
        AgentProfileReference::new(self.id.clone()).with_version(self.version)
    }
}

impl AgentProfileReference {
    pub fn new(profile_id: AgentProfileId) -> Self {
        Self {
            profile_id,
            profile_version: None,
        }
    }

    pub fn with_version(mut self, profile_version: AgentProfileVersion) -> Self {
        self.profile_version = Some(profile_version);
        self
    }

    pub fn profile_id(&self) -> &AgentProfileId {
        &self.profile_id
    }

    pub fn profile_version(&self) -> Option<AgentProfileVersion> {
        self.profile_version
    }
}
