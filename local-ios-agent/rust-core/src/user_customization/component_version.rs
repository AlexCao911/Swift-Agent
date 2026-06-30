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
