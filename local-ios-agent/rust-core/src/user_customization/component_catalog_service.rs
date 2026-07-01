use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::core::AgentError;
use crate::storage::{
    InMemoryTransactionRunner, PendingStoreWrite, StorageError, StorageResult, TransactionName,
    TransactionOperation, TransactionRunner, UnitOfWork,
};
use crate::user_customization::{
    ComponentContent, ComponentValidator, PublishedUserComponentVersion, UserComponent,
    UserComponentId, UserComponentVersionId,
};

#[derive(Clone, Debug)]
pub struct ComponentCatalogService {
    inner: Arc<Mutex<ComponentCatalogRecords>>,
}

#[derive(Debug)]
struct ComponentCatalogRecords {
    components: BTreeMap<UserComponentId, UserComponent>,
    versions: BTreeMap<UserComponentVersionId, PublishedUserComponentVersion>,
    next_component_id: u64,
    next_version_id: u64,
}

#[derive(Clone, Debug)]
struct ComponentPublishCommit {
    component_id: UserComponentId,
    version: PublishedUserComponentVersion,
}

struct PendingComponentPublishWrite {
    catalog: ComponentCatalogService,
    commit: ComponentPublishCommit,
}

struct ComponentPublishOperation {
    catalog: ComponentCatalogService,
    component_id: UserComponentId,
    result: Option<UserComponentVersionId>,
}

impl Default for ComponentCatalogService {
    fn default() -> Self {
        Self {
            inner: Arc::new(Mutex::new(ComponentCatalogRecords {
                components: BTreeMap::new(),
                versions: BTreeMap::new(),
                next_component_id: 1,
                next_version_id: 1,
            })),
        }
    }
}

impl ComponentCatalogService {
    pub fn create_draft(&self, content: ComponentContent) -> UserComponentId {
        let mut inner = self.inner.lock().expect("component catalog mutex poisoned");
        let id = UserComponentId(inner.next_component_id);
        inner.next_component_id += 1;
        inner.components.insert(id, UserComponent::new(id, content));
        id
    }

    pub fn update_draft(
        &self,
        id: UserComponentId,
        content: ComponentContent,
    ) -> Result<(), AgentError> {
        let mut inner = self.inner.lock().expect("component catalog mutex poisoned");
        let component = inner
            .components
            .get_mut(&id)
            .ok_or_else(|| AgentError::Unknown(format!("component draft not found: {id:?}")))?;
        component.update_draft(content)
    }

    pub fn publish(&self, id: UserComponentId) -> Result<UserComponentVersionId, AgentError> {
        self.publish_with_runner(&InMemoryTransactionRunner::default(), id)
            .map_err(|error| AgentError::Storage(error.to_string()))
    }

    pub fn publish_with_runner(
        &self,
        runner: &dyn TransactionRunner,
        id: UserComponentId,
    ) -> StorageResult<UserComponentVersionId> {
        let mut operation = ComponentPublishOperation {
            catalog: self.clone(),
            component_id: id,
            result: None,
        };

        runner.run(TransactionName::new("component.publish"), &mut operation)?;
        operation.result.ok_or_else(|| {
            StorageError::new(
                "component.publish_failed",
                "component publish operation did not produce a version id",
            )
        })
    }

    fn prepare_publish_commit(
        &self,
        component_id: UserComponentId,
    ) -> StorageResult<ComponentPublishCommit> {
        let inner = self.inner.lock().expect("component catalog mutex poisoned");
        let component = inner
            .components
            .get(&component_id)
            .ok_or_else(|| StorageError::new("component.not_found", "component draft not found"))?;
        let content = component.current_draft().clone();
        let validation = ComponentValidator::default().validate(&content);
        if !validation.is_valid {
            let issue_codes = validation
                .issues
                .iter()
                .map(|issue| issue.code.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            return Err(StorageError::new(
                "component.validation_failed",
                format!("component validation failed: {issue_codes}"),
            ));
        }

        let version_id = UserComponentVersionId(inner.next_version_id);
        Ok(ComponentPublishCommit {
            component_id,
            version: PublishedUserComponentVersion::new(version_id, component_id, content),
        })
    }

    fn stage_publish(
        &self,
        tx: &mut UnitOfWork,
        commit: ComponentPublishCommit,
    ) -> StorageResult<()> {
        tx.push_store_write(Box::new(PendingComponentPublishWrite {
            catalog: self.clone(),
            commit,
        }));
        Ok(())
    }

    fn validate_publish_commit(&self, commit: &ComponentPublishCommit) -> StorageResult<()> {
        let inner = self.inner.lock().expect("component catalog mutex poisoned");
        if !inner.components.contains_key(&commit.component_id) {
            return Err(StorageError::new(
                "component.not_found",
                "component draft not found",
            ));
        }
        if commit.version.id != UserComponentVersionId(inner.next_version_id)
            || inner.versions.contains_key(&commit.version.id)
        {
            return Err(StorageError::new(
                "component.version_conflict",
                "component version id is no longer current",
            ));
        }
        Ok(())
    }

    fn commit_publish(&self, commit: ComponentPublishCommit) {
        let mut inner = self.inner.lock().expect("component catalog mutex poisoned");
        let component = inner
            .components
            .get_mut(&commit.component_id)
            .expect("validated component publish commit must reference existing component");
        component.record_published_version(commit.version.id);
        inner.next_version_id += 1;
        inner.versions.insert(commit.version.id, commit.version);
    }

    pub fn component(&self, id: UserComponentId) -> Option<UserComponent> {
        self.inner
            .lock()
            .expect("component catalog mutex poisoned")
            .components
            .get(&id)
            .cloned()
    }

    pub fn version(&self, id: UserComponentVersionId) -> Option<PublishedUserComponentVersion> {
        self.inner
            .lock()
            .expect("component catalog mutex poisoned")
            .versions
            .get(&id)
            .cloned()
    }
}

impl TransactionOperation for ComponentPublishOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let commit = self.catalog.prepare_publish_commit(self.component_id)?;
        let version_id = commit.version.id;
        self.catalog.stage_publish(tx, commit)?;
        self.result = Some(version_id);
        Ok(())
    }
}

impl PendingStoreWrite for PendingComponentPublishWrite {
    fn validate(&self) -> StorageResult<()> {
        self.catalog.validate_publish_commit(&self.commit)
    }

    fn commit(self: Box<Self>) {
        self.catalog.commit_publish(self.commit);
    }
}
