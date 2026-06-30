use crate::core::AgentError;
use crate::user_customization::{ComponentContent, ComponentKind, UserComponentVersionId};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct UserComponentId(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserComponentDraft {
    pub id: UserComponentId,
    pub content: ComponentContent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserComponent {
    id: UserComponentId,
    kind: ComponentKind,
    current_draft: ComponentContent,
    published_versions: Vec<UserComponentVersionId>,
}

impl UserComponent {
    pub fn new(id: UserComponentId, content: ComponentContent) -> Self {
        Self {
            id,
            kind: content.kind(),
            current_draft: content,
            published_versions: Vec::new(),
        }
    }

    pub fn id(&self) -> UserComponentId {
        self.id
    }

    pub fn kind(&self) -> ComponentKind {
        self.kind
    }

    pub fn current_draft(&self) -> &ComponentContent {
        &self.current_draft
    }

    pub fn update_draft(&mut self, content: ComponentContent) -> Result<(), AgentError> {
        if content.kind() != self.kind {
            return Err(AgentError::Unknown(format!(
                "component kind mismatch: expected {:?}, got {:?}",
                self.kind,
                content.kind()
            )));
        }
        self.current_draft = content;
        Ok(())
    }

    pub fn record_published_version(&mut self, id: UserComponentVersionId) {
        self.published_versions.push(id);
    }

    pub fn published_versions(&self) -> &[UserComponentVersionId] {
        &self.published_versions
    }
}
