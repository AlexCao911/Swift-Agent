#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum AgentSlotKind {
    Brain,
    Persona,
    Instruction,
    Model,
    Toolset,
    Memory,
    Voice,
}

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct AgentSlotId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentSlot {
    id: AgentSlotId,
    kind: AgentSlotKind,
    required: bool,
}

impl AgentSlot {
    pub fn required(id: AgentSlotId, kind: AgentSlotKind) -> Self {
        Self {
            id,
            kind,
            required: true,
        }
    }

    pub fn optional(id: AgentSlotId, kind: AgentSlotKind) -> Self {
        Self {
            id,
            kind,
            required: false,
        }
    }

    pub fn id(&self) -> &AgentSlotId {
        &self.id
    }

    pub fn kind(&self) -> AgentSlotKind {
        self.kind
    }

    pub fn is_required(&self) -> bool {
        self.required
    }
}

impl AgentSlotId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}
