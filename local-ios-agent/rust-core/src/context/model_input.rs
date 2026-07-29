use serde::Serialize;

use crate::agent_input::ToolDefinitionSnapshot;
use crate::context::{ContextAssemblyTrace, ContextSegmentId};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelInputRole {
    System,
    User,
    Assistant,
    Tool,
    Summary,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelInputMessages {
    messages: Vec<ModelInputMessage>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelInputMessage {
    role: ModelInputRole,
    content: String,
    blob_refs: Vec<String>,
    source_segment_id: ContextSegmentId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTurnInput {
    system_prompt: String,
    ordered_messages: ModelInputMessages,
    ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
    context_trace: ContextAssemblyTrace,
    compaction_summary: Option<String>,
}

impl ModelInputMessages {
    pub(crate) fn new(messages: Vec<ModelInputMessage>) -> Self {
        Self { messages }
    }

    pub fn messages(&self) -> &[ModelInputMessage] {
        &self.messages
    }
}

impl ModelInputMessage {
    pub(crate) fn new(
        role: ModelInputRole,
        content: impl Into<String>,
        blob_refs: Vec<String>,
        source_segment_id: ContextSegmentId,
    ) -> Self {
        Self {
            role,
            content: content.into(),
            blob_refs,
            source_segment_id,
        }
    }

    pub fn role(&self) -> ModelInputRole {
        self.role
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn blob_refs(&self) -> &[String] {
        &self.blob_refs
    }

    pub fn source_segment_id(&self) -> &str {
        self.source_segment_id.as_str()
    }
}

impl AgentTurnInput {
    pub(crate) fn new(
        system_prompt: String,
        ordered_messages: ModelInputMessages,
        ordered_tool_definitions: Vec<ToolDefinitionSnapshot>,
        context_trace: ContextAssemblyTrace,
        compaction_summary: Option<String>,
    ) -> Self {
        Self {
            system_prompt,
            ordered_messages,
            ordered_tool_definitions,
            context_trace,
            compaction_summary,
        }
    }

    pub fn system_prompt(&self) -> &str {
        &self.system_prompt
    }

    pub fn ordered_messages(&self) -> &ModelInputMessages {
        &self.ordered_messages
    }

    pub fn ordered_tool_definitions(&self) -> &[ToolDefinitionSnapshot] {
        &self.ordered_tool_definitions
    }

    pub fn context_trace(&self) -> &ContextAssemblyTrace {
        &self.context_trace
    }

    pub fn compaction_summary(&self) -> Option<&str> {
        self.compaction_summary.as_deref()
    }
}
