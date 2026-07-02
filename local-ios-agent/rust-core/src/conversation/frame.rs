use crate::core::{EntryId, SessionId};

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ConversationFrameId(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationRunFrameRef {
    frame_id: ConversationFrameId,
    session_id: SessionId,
    branch_head_id: EntryId,
    user_turn_id: EntryId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationRunFrame {
    frame_ref: ConversationRunFrameRef,
    parent_event_id: Option<EntryId>,
    messages: Vec<ConversationFrameMessage>,
    attachment_refs: Vec<AttachmentRef>,
    lineage: ConversationLineage,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationFrameMessage {
    event_id: EntryId,
    role: ConversationFrameRole,
    content: String,
    blob_refs: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum ConversationFrameRole {
    User,
    Assistant,
    Summary,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AttachmentRef(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationLineage {
    branch_head_id: EntryId,
    fork_origin_id: Option<EntryId>,
    edit_origin_id: Option<EntryId>,
}

impl ConversationFrameId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ConversationRunFrameRef {
    pub fn new(
        frame_id: ConversationFrameId,
        session_id: SessionId,
        branch_head_id: EntryId,
        user_turn_id: EntryId,
    ) -> Self {
        Self {
            frame_id,
            session_id,
            branch_head_id,
            user_turn_id,
        }
    }

    pub fn frame_id(&self) -> &ConversationFrameId {
        &self.frame_id
    }

    pub fn session_id(&self) -> &SessionId {
        &self.session_id
    }

    pub fn branch_head_id(&self) -> &EntryId {
        &self.branch_head_id
    }

    pub fn user_turn_id(&self) -> &EntryId {
        &self.user_turn_id
    }
}

impl ConversationRunFrame {
    pub fn new(
        frame_ref: ConversationRunFrameRef,
        parent_event_id: Option<EntryId>,
        messages: Vec<ConversationFrameMessage>,
        attachment_refs: Vec<AttachmentRef>,
        lineage: ConversationLineage,
    ) -> Self {
        Self {
            frame_ref,
            parent_event_id,
            messages,
            attachment_refs,
            lineage,
        }
    }

    pub fn frame_ref(&self) -> &ConversationRunFrameRef {
        &self.frame_ref
    }

    pub fn parent_event_id(&self) -> Option<&EntryId> {
        self.parent_event_id.as_ref()
    }

    pub fn messages(&self) -> &[ConversationFrameMessage] {
        &self.messages
    }

    pub fn attachment_refs(&self) -> &[AttachmentRef] {
        &self.attachment_refs
    }

    pub fn lineage(&self) -> &ConversationLineage {
        &self.lineage
    }

    pub fn system_prompt(&self) -> Option<&str> {
        None
    }
}

impl ConversationFrameMessage {
    pub fn user(event_id: EntryId, content: impl Into<String>) -> Self {
        Self {
            event_id,
            role: ConversationFrameRole::User,
            content: content.into(),
            blob_refs: Vec::new(),
        }
    }

    pub fn assistant(event_id: EntryId, content: impl Into<String>) -> Self {
        Self {
            event_id,
            role: ConversationFrameRole::Assistant,
            content: content.into(),
            blob_refs: Vec::new(),
        }
    }

    pub fn summary(event_id: EntryId, content: impl Into<String>) -> Self {
        Self {
            event_id,
            role: ConversationFrameRole::Summary,
            content: content.into(),
            blob_refs: Vec::new(),
        }
    }

    pub fn with_blob_refs(mut self, blob_refs: Vec<String>) -> Self {
        self.blob_refs = blob_refs;
        self
    }

    pub fn event_id(&self) -> &EntryId {
        &self.event_id
    }

    pub fn role(&self) -> &str {
        match self.role {
            ConversationFrameRole::User => "user",
            ConversationFrameRole::Assistant => "assistant",
            ConversationFrameRole::Summary => "summary",
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn blob_refs(&self) -> &[String] {
        &self.blob_refs
    }
}

impl AttachmentRef {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl ConversationLineage {
    pub fn new(
        branch_head_id: EntryId,
        fork_origin_id: Option<EntryId>,
        edit_origin_id: Option<EntryId>,
    ) -> Self {
        Self {
            branch_head_id,
            fork_origin_id,
            edit_origin_id,
        }
    }

    pub fn branch_head_id(&self) -> &EntryId {
        &self.branch_head_id
    }

    pub fn fork_origin_id(&self) -> Option<&EntryId> {
        self.fork_origin_id.as_ref()
    }

    pub fn edit_origin_id(&self) -> Option<&EntryId> {
        self.edit_origin_id.as_ref()
    }
}
