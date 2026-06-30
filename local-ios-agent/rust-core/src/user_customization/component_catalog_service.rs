use std::collections::BTreeMap;

use crate::core::AgentError;
use crate::user_customization::{
    ComponentContent, PublishedUserComponentVersion, UserComponentDraft, UserComponentId,
    UserComponentVersionId,
};

#[derive(Debug)]
pub struct ComponentCatalogService {
    drafts: BTreeMap<UserComponentId, UserComponentDraft>,
    versions: BTreeMap<UserComponentVersionId, PublishedUserComponentVersion>,
    next_component_id: u64,
    next_version_id: u64,
}

impl Default for ComponentCatalogService {
    fn default() -> Self {
        Self {
            drafts: BTreeMap::new(),
            versions: BTreeMap::new(),
            next_component_id: 1,
            next_version_id: 1,
        }
    }
}

impl ComponentCatalogService {
    pub fn create_draft(&mut self, content: ComponentContent) -> UserComponentId {
        let id = UserComponentId(self.next_component_id);
        self.next_component_id += 1;
        self.drafts.insert(id, UserComponentDraft { id, content });
        id
    }

    pub fn update_draft(
        &mut self,
        id: UserComponentId,
        content: ComponentContent,
    ) -> Result<(), AgentError> {
        let draft = self
            .drafts
            .get_mut(&id)
            .ok_or_else(|| AgentError::Unknown(format!("component draft not found: {id:?}")))?;
        draft.content = content;
        Ok(())
    }

    pub fn publish(&mut self, id: UserComponentId) -> Result<UserComponentVersionId, AgentError> {
        let draft = self
            .drafts
            .get(&id)
            .ok_or_else(|| AgentError::Unknown(format!("component draft not found: {id:?}")))?;
        let version_id = UserComponentVersionId(self.next_version_id);
        self.next_version_id += 1;
        self.versions.insert(
            version_id,
            PublishedUserComponentVersion::new(version_id, id, draft.content.clone()),
        );
        Ok(version_id)
    }

    pub fn version(&self, id: UserComponentVersionId) -> Option<&PublishedUserComponentVersion> {
        self.versions.get(&id)
    }
}
