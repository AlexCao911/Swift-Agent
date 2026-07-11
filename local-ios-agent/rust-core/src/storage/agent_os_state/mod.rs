mod in_memory;
mod sqlite;

pub use in_memory::InMemoryAgentOSStateStore;
pub use sqlite::SqliteAgentOSStateStore;

use crate::llm_contracts::{
    HostBindingCommit, HostBindingCrossLink, HostBindingError, HostBindingOperation,
    PackageBindingPreparation, ProfilePublishPreparation,
};

pub trait AgentOSStateRepository {
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
