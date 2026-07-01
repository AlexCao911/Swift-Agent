use serde::Serialize;

use crate::context::ModelInputRole;
use crate::prompt::PromptSourceMap;

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub struct ContextSegmentId(String);

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum SegmentSource {
    SystemGuardrail,
    Prompt,
    SkillInstruction,
    Conversation,
    Memory,
    ToolResult,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextSensitivity {
    Public,
    Normal,
    Sensitive,
    Secret,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SegmentProvenance(String);

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ContextSourceLink {
    kind: String,
    id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContextSegment {
    id: ContextSegmentId,
    source: SegmentSource,
    priority: i32,
    sensitivity: ContextSensitivity,
    provenance: SegmentProvenance,
    model_role: ModelInputRole,
    budget_priority: i32,
    required_for_model_input: bool,
    blob_refs: Vec<String>,
    source_links: Vec<ContextSourceLink>,
    prompt_source_map: Option<PromptSourceMap>,
    content: String,
}

impl ContextSegment {
    pub fn prompt(id: impl Into<String>, content: impl Into<String>) -> Self {
        Self::new(id, SegmentSource::Prompt, content)
            .with_priority(100)
            .with_model_role(ModelInputRole::System)
    }

    pub fn memory(id: impl Into<String>, content: impl Into<String>) -> Self {
        Self::new(id, SegmentSource::Memory, content)
            .with_priority(40)
            .with_model_role(ModelInputRole::User)
    }

    pub fn tool_result(id: impl Into<String>, content: impl Into<String>) -> Self {
        Self::new(id, SegmentSource::ToolResult, content)
            .with_priority(30)
            .with_model_role(ModelInputRole::Tool)
    }

    pub fn conversation(id: impl Into<String>, content: impl Into<String>) -> Self {
        Self::new(id, SegmentSource::Conversation, content)
            .with_priority(60)
            .with_model_role(ModelInputRole::User)
    }

    pub fn skill_instruction(id: impl Into<String>, content: impl Into<String>) -> Self {
        Self::new(id, SegmentSource::SkillInstruction, content)
            .with_priority(80)
            .with_model_role(ModelInputRole::System)
    }

    pub fn system_guardrail(id: impl Into<String>, content: impl Into<String>) -> Self {
        Self::new(id, SegmentSource::SystemGuardrail, content)
            .with_priority(110)
            .with_model_role(ModelInputRole::System)
    }

    pub fn with_priority(mut self, priority: i32) -> Self {
        self.priority = priority;
        self.budget_priority = priority;
        self
    }

    pub fn with_budget_priority(mut self, budget_priority: i32) -> Self {
        self.budget_priority = budget_priority;
        self
    }

    pub fn with_sensitivity(mut self, sensitivity: ContextSensitivity) -> Self {
        self.sensitivity = sensitivity;
        self
    }

    pub fn with_provenance(mut self, provenance: impl Into<String>) -> Self {
        self.provenance = SegmentProvenance(provenance.into());
        self
    }

    pub fn with_model_role(mut self, role: ModelInputRole) -> Self {
        self.model_role = role;
        self
    }

    pub fn with_blob_refs(mut self, blob_refs: Vec<String>) -> Self {
        self.blob_refs = blob_refs;
        self
    }

    pub fn with_source_link(mut self, kind: impl Into<String>, id: impl Into<String>) -> Self {
        self.source_links.push(ContextSourceLink::new(kind, id));
        self
    }

    pub fn with_prompt_source_map(mut self, source_map: PromptSourceMap) -> Self {
        self.prompt_source_map = Some(source_map);
        self
    }

    pub fn required_for_model_input(mut self) -> Self {
        self.required_for_model_input = true;
        self
    }

    pub fn id(&self) -> &ContextSegmentId {
        &self.id
    }

    pub fn source(&self) -> SegmentSource {
        self.source
    }

    pub fn priority(&self) -> i32 {
        self.priority
    }

    pub fn budget_priority(&self) -> i32 {
        self.budget_priority
    }

    pub fn is_required_for_model_input(&self) -> bool {
        self.required_for_model_input
    }

    pub fn sensitivity(&self) -> ContextSensitivity {
        self.sensitivity
    }

    pub fn provenance(&self) -> &SegmentProvenance {
        &self.provenance
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn model_role(&self) -> ModelInputRole {
        self.model_role
    }

    pub fn blob_refs(&self) -> &[String] {
        &self.blob_refs
    }

    pub fn source_links(&self) -> &[ContextSourceLink] {
        &self.source_links
    }

    pub fn prompt_source_map(&self) -> Option<&PromptSourceMap> {
        self.prompt_source_map.as_ref()
    }

    fn new(id: impl Into<String>, source: SegmentSource, content: impl Into<String>) -> Self {
        let id = id.into();
        Self {
            id: ContextSegmentId(id.clone()),
            source,
            priority: 0,
            sensitivity: ContextSensitivity::Normal,
            provenance: SegmentProvenance(format!("context.{id}")),
            model_role: ModelInputRole::User,
            budget_priority: 0,
            required_for_model_input: false,
            blob_refs: Vec::new(),
            source_links: Vec::new(),
            prompt_source_map: None,
            content: content.into(),
        }
    }
}

impl ContextSegmentId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl SegmentSource {
    pub(crate) fn rank(self) -> u8 {
        match self {
            Self::SystemGuardrail => 0,
            Self::Prompt => 1,
            Self::SkillInstruction => 2,
            Self::Conversation => 3,
            Self::Memory => 4,
            Self::ToolResult => 5,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::SystemGuardrail => "system_guardrail",
            Self::Prompt => "prompt",
            Self::SkillInstruction => "skill_instruction",
            Self::Conversation => "conversation",
            Self::Memory => "memory",
            Self::ToolResult => "tool_result",
        }
    }
}

impl SegmentProvenance {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ContextSourceLink {
    pub fn new(kind: impl Into<String>, id: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            id: id.into(),
        }
    }

    pub fn kind(&self) -> &str {
        &self.kind
    }

    pub fn id(&self) -> &str {
        &self.id
    }
}
