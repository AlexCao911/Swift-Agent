mod in_memory;
mod sqlite;

pub use in_memory::InMemoryAgentOSStateStore;
pub use sqlite::SqliteAgentOSStateStore;

use crate::llm_contracts::{
    GlobalRunLease, GlobalRunLeaseError, HostBindingCommit, HostBindingCrossLink, HostBindingError,
    HostBindingOperation, PackageBindingPreparation, PreparationError,
    PreparedSessionCleanupAcknowledgement, ProfilePublishPreparation, RunPreparationRecord,
};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PreparedRunConsumption {
    pub preparation_id: String,
    pub proposed_run_id: String,
    pub token_digest: String,
    pub lease_generation: u64,
    pub session_handle: String,
    pub host_process_epoch: String,
    pub binding_id: String,
    pub binding_revision: u64,
    pub binding_hash: String,
}

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

pub trait RunPreparationRepository {
    fn consume_registered_preparation_and_promote(
        &mut self,
        request: &PreparedRunConsumption,
    ) -> Result<(), PreparationError>;
    fn create_preparation_and_acquire_lease(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn create_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn save_run_preparation(
        &mut self,
        expected_state: crate::llm_contracts::RunPreparationState,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn renew_preparation_and_lease(
        &mut self,
        expected_state: crate::llm_contracts::RunPreparationState,
        expected_token_generation: u64,
        expected_token_digest: &str,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn recover_preparations_for_new_epoch(
        &mut self,
        current_host_epoch: &str,
    ) -> Result<Vec<String>, PreparationError>;
    fn abort_run_preparation(
        &mut self,
        record: RunPreparationRecord,
        has_registered_session: bool,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn acknowledge_prepared_cleanup(
        &mut self,
        record: RunPreparationRecord,
        acknowledgement: &PreparedSessionCleanupAcknowledgement,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn close_run_preparation(
        &mut self,
        record: RunPreparationRecord,
    ) -> Result<RunPreparationRecord, PreparationError>;
    fn run_preparation(
        &self,
        preparation_id: &str,
    ) -> Result<Option<RunPreparationRecord>, PreparationError>;
    fn active_run_preparation(&self) -> Result<Option<RunPreparationRecord>, PreparationError>;
    fn list_run_preparations(&self) -> Result<Vec<RunPreparationRecord>, PreparationError>;
}

pub trait AgentOSStateRepository:
    GlobalRunLeaseRepository + RunPreparationRepository + Send
{
    fn prepare_profile_publish(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError>;
    fn commit_profile_publish(
        &mut self,
        request: HostBindingCommit,
    ) -> Result<HostBindingCrossLink, HostBindingError>;
    fn prepare_profile_rebind(
        &mut self,
        request: ProfilePublishPreparation,
    ) -> Result<HostBindingOperation, HostBindingError>;
    fn commit_profile_rebind(
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
    #[allow(clippy::too_many_arguments)]
    fn matching_cross_link(
        &self,
        agent_profile_id: &str,
        agent_profile_revision: u64,
        llm_slot_id: &str,
        requirements_hash: &str,
        binding_id: &str,
        binding_revision: u64,
        binding_hash: &str,
    ) -> Result<Option<HostBindingCrossLink>, HostBindingError>;
    fn activate_matching_cross_link(
        &mut self,
        confirmation: &crate::llm_contracts::HostBindingActivationConfirmation,
    ) -> Result<HostBindingCrossLink, HostBindingError>;
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

    pub fn with_preparation_mut<T>(
        &self,
        operation: impl FnOnce(&mut dyn AgentOSStateRepository) -> Result<T, PreparationError>,
    ) -> Result<T, PreparationError> {
        let mut store = self.inner.lock().map_err(|_| preparation_poisoned())?;
        operation(store.as_mut())
    }

    pub fn with_preparation<T>(
        &self,
        operation: impl FnOnce(&dyn AgentOSStateRepository) -> Result<T, PreparationError>,
    ) -> Result<T, PreparationError> {
        let store = self.inner.lock().map_err(|_| preparation_poisoned())?;
        operation(store.as_ref())
    }

    pub fn with_host_binding_mut<T>(
        &self,
        operation: impl FnOnce(&mut dyn AgentOSStateRepository) -> Result<T, HostBindingError>,
    ) -> Result<T, HostBindingError> {
        let mut store = self.inner.lock().map_err(|_| host_binding_poisoned())?;
        operation(store.as_mut())
    }

    pub fn with_host_binding<T>(
        &self,
        operation: impl FnOnce(&dyn AgentOSStateRepository) -> Result<T, HostBindingError>,
    ) -> Result<T, HostBindingError> {
        let store = self.inner.lock().map_err(|_| host_binding_poisoned())?;
        operation(store.as_ref())
    }
}

fn poisoned() -> GlobalRunLeaseError {
    GlobalRunLeaseError::new(
        "execution.global_run_lease_store_poisoned",
        "global run lease store mutex is poisoned",
    )
}

fn preparation_poisoned() -> PreparationError {
    PreparationError::new(
        "preparation.store_poisoned",
        "run preparation store mutex is poisoned",
    )
}

fn host_binding_poisoned() -> HostBindingError {
    HostBindingError::new(
        "host_binding.store_poisoned",
        "host-binding store mutex is poisoned",
    )
}
