use crate::user_customization::{ComponentContent, UserComponentId};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct UserComponentVersionId(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PublishedUserComponentVersion {
    pub id: UserComponentVersionId,
    pub component_id: UserComponentId,
    content: ComponentContent,
}

impl PublishedUserComponentVersion {
    pub fn new(
        id: UserComponentVersionId,
        component_id: UserComponentId,
        content: ComponentContent,
    ) -> Self {
        Self {
            id,
            component_id,
            content,
        }
    }

    pub fn content(&self) -> &ComponentContent {
        &self.content
    }

    pub fn content_text(&self) -> &str {
        self.content.content_text()
    }
}

impl UserComponentVersionId {
    pub fn new(value: u64) -> Self {
        Self(value)
    }

    pub fn as_u64(&self) -> u64 {
        self.0
    }

    pub fn is_published(&self) -> bool {
        self.0 != 0
    }

    pub fn stable_key(&self) -> String {
        format!("component_version.{}", self.0)
    }
}
