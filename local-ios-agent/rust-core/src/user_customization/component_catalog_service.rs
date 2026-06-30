use std::collections::BTreeMap;

use crate::core::AgentError;
use crate::user_customization::{
    ComponentContent, ComponentValidator, PublishedUserComponentVersion, UserComponent,
    UserComponentId, UserComponentVersionId,
};

#[derive(Debug)]
pub struct ComponentCatalogService {
    components: BTreeMap<UserComponentId, UserComponent>,
    versions: BTreeMap<UserComponentVersionId, PublishedUserComponentVersion>,
    next_component_id: u64,
    next_version_id: u64,
}

impl Default for ComponentCatalogService {
    fn default() -> Self {
        Self {
            components: BTreeMap::new(),
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
        self.components.insert(id, UserComponent::new(id, content));
        id
    }

    pub fn update_draft(
        &mut self,
        id: UserComponentId,
        content: ComponentContent,
    ) -> Result<(), AgentError> {
        let component = self
            .components
            .get_mut(&id)
            .ok_or_else(|| AgentError::Unknown(format!("component draft not found: {id:?}")))?;
        component.update_draft(content)
    }

    pub fn publish(&mut self, id: UserComponentId) -> Result<UserComponentVersionId, AgentError> {
        let component = self
            .components
            .get_mut(&id)
            .ok_or_else(|| AgentError::Unknown(format!("component draft not found: {id:?}")))?;
        let content = component.current_draft().clone();
        let validation = ComponentValidator::default().validate(&content);
        if !validation.is_valid {
            let issue_codes = validation
                .issues
                .iter()
                .map(|issue| issue.code.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            return Err(AgentError::Unknown(format!(
                "component validation failed: {issue_codes}"
            )));
        }

        let version_id = UserComponentVersionId(self.next_version_id);
        self.next_version_id += 1;
        self.versions.insert(
            version_id,
            PublishedUserComponentVersion::new(version_id, id, content),
        );
        component.record_published_version(version_id);
        Ok(version_id)
    }

    pub fn component(&self, id: UserComponentId) -> Option<&UserComponent> {
        self.components.get(&id)
    }

    pub fn version(&self, id: UserComponentVersionId) -> Option<&PublishedUserComponentVersion> {
        self.versions.get(&id)
    }
}
