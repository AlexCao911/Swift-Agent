use crate::user_customization::{AgentSlot, AgentSlotId, AgentSlotKind};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTemplate {
    id: AgentTemplateId,
    slots: Vec<AgentSlot>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTemplateId(String);

impl AgentTemplate {
    pub fn assistant_default() -> Self {
        Self {
            id: AgentTemplateId::new("template.assistant.default"),
            slots: vec![
                AgentSlot::optional(AgentSlotId::new("slot.brain.primary"), AgentSlotKind::Brain),
                AgentSlot::required(
                    AgentSlotId::new("slot.persona.primary"),
                    AgentSlotKind::Persona,
                ),
                AgentSlot::optional(
                    AgentSlotId::new("slot.instructions.primary"),
                    AgentSlotKind::Instruction,
                ),
                AgentSlot::required(AgentSlotId::new("slot.model.primary"), AgentSlotKind::Model),
                AgentSlot::optional(
                    AgentSlotId::new("slot.toolset.primary"),
                    AgentSlotKind::Toolset,
                ),
                AgentSlot::optional(
                    AgentSlotId::new("slot.memory.primary"),
                    AgentSlotKind::Memory,
                ),
                AgentSlot::optional(AgentSlotId::new("slot.voice.primary"), AgentSlotKind::Voice),
            ],
        }
    }

    pub fn package_installed_v1() -> Self {
        Self {
            id: AgentTemplateId::new("template.package.installed.v1"),
            slots: vec![AgentSlot::required(
                AgentSlotId::new("slot.model.primary"),
                AgentSlotKind::Model,
            )],
        }
    }

    pub fn id(&self) -> &AgentTemplateId {
        &self.id
    }

    pub fn slots(&self) -> &[AgentSlot] {
        &self.slots
    }

    pub fn requires_slot(&self, kind: AgentSlotKind) -> bool {
        self.slots
            .iter()
            .any(|slot| slot.kind() == kind && slot.is_required())
    }

    pub fn supports_slot(&self, kind: AgentSlotKind) -> bool {
        self.slots.iter().any(|slot| slot.kind() == kind)
    }

    pub fn slot_id_for_kind(&self, kind: AgentSlotKind) -> Option<&AgentSlotId> {
        self.slots
            .iter()
            .find(|slot| slot.kind() == kind)
            .map(AgentSlot::id)
    }

    pub fn slot_for_id(&self, slot_id: &AgentSlotId) -> Option<&AgentSlot> {
        self.slots.iter().find(|slot| slot.id() == slot_id)
    }

    pub fn supports_slot_id(&self, slot_id: &AgentSlotId) -> bool {
        self.slots.iter().any(|slot| slot.id() == slot_id)
    }
}

impl AgentTemplateId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}
