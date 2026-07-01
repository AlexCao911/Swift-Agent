use serde::Serialize;

use crate::context::ContextSegmentId;

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
