mod in_memory;
mod sqlite;

pub use in_memory::InMemoryAgentOSStateStore;
pub use sqlite::SqliteAgentOSStateStore;

use crate::llm_contracts::{
    GlobalRunLease, GlobalRunLeaseError, HostBindingCommit, HostBindingCrossLink, HostBindingError,
    HostBindingOperation, PackageBindingPreparation, ProfilePublishPreparation,
};
use std::sync::{Arc, Mutex};

pub trait GlobalRunLeaseRepository {
    fn acquire_legacy(
        &mut self,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError>;
    fn acquire_preparation(
        &mut self,
        preparation_id: &str,
        host_epoch: &str,
        expiration: u64,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError>;
    fn promote_preparation(
        &mut self,
        generation: u64,
        preparation_id: &str,
        run_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError>;
    fn begin_release(
        &mut self,
        generation: u64,
        owner_id: &str,
        host_epoch: &str,
    ) -> Result<GlobalRunLease, GlobalRunLeaseError>;
    fn complete_release(
        &mut self,
        generation: u64,
        host_epoch: &str,
    ) -> Result<(), GlobalRunLeaseError>;
    fn recover_old_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError>;
    fn current_global_run_lease(&self) -> Result<Option<GlobalRunLease>, GlobalRunLeaseError>;
}

pub trait AgentOSStateRepository: GlobalRunLeaseRepository + Send {
    fn prepare_profile_publish(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError>;
    fn commit_profile_publish(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError>;
    fn begin_package_binding(
        &mut self,
        request: PackageBindingPreparation,
    ) -> Result<HostBindingOperation, HostBindingError>;
    fn attach_host_binding(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError>;
    fn cross_link(
        &self,
        operation_token: &str,
    ) -> Result<Option<HostBindingCrossLink>, HostBindingError>;
}

#[derive(Clone)]
pub struct SharedAgentOSStateStore {
    inner: Arc<Mutex<Box<dyn AgentOSStateRepository>>>,
}

impl SharedAgentOSStateStore {
    pub fn in_memory() -> Self {
        Self::new(InMemoryAgentOSStateStore::new())
    }

    pub fn new(store: impl AgentOSStateRepository + 'static) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Box::new(store))),
        }
    }

    pub fn with_mut<T>(
        &self,
        operation: impl FnOnce(&mut dyn AgentOSStateRepository) -> Result<T, GlobalRunLeaseError>,
    ) -> Result<T, GlobalRunLeaseError> {
        let mut store = self.inner.lock().map_err(|_| poisoned())?;
        operation(store.as_mut())
    }

    pub fn with<T>(
        &self,
        operation: impl FnOnce(&dyn AgentOSStateRepository) -> Result<T, GlobalRunLeaseError>,
    ) -> Result<T, GlobalRunLeaseError> {
        let store = self.inner.lock().map_err(|_| poisoned())?;
        operation(store.as_ref())
    }
}

fn poisoned() -> GlobalRunLeaseError {
    GlobalRunLeaseError::new(
        "execution.global_run_lease_store_poisoned",
        "global run lease store mutex is poisoned",
    )
}
