use std::sync::Arc;

use local_ios_agent_runtime::agent_package::{
    AgentPackageInstaller, AgentPackageManifest, InMemoryPackageInstallStore,
    InstalledAgentProfileReference, LocalBindings,
};
use local_ios_agent_runtime::model::InMemoryModelBindingCatalog;
use local_ios_agent_runtime::security::{
    EgressDestination, SecurityManager, StaticSecurityPermissionService,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::{
    ComponentCatalogService, InMemoryAgentProfileRepository,
};

#[derive(Clone)]
pub struct AgentOsTestWorld {
    pub package_store: InMemoryPackageInstallStore,
    pub profile_repository: InMemoryAgentProfileRepository,
    pub model_catalog: InMemoryModelBindingCatalog,
    pub component_catalog: ComponentCatalogService,
    pub security: SecurityManager,
}

impl AgentOsTestWorld {
    pub fn new() -> Self {
        let permission_service = Arc::new(
            StaticSecurityPermissionService::default()
                .allow_destination(EgressDestination::new("https://api.openai.com"))
                .allow_destination(EgressDestination::new("https://memory.example.com")),
        );

        Self {
            package_store: InMemoryPackageInstallStore::default(),
            profile_repository: InMemoryAgentProfileRepository::default(),
            model_catalog: InMemoryModelBindingCatalog::default(),
            component_catalog: ComponentCatalogService::default(),
            security: SecurityManager::with_permission_service(permission_service),
        }
    }

    pub fn package_installer(&self) -> AgentPackageInstaller {
        AgentPackageInstaller::new(
            Box::new(InMemoryTransactionRunner::default()),
            self.package_store.clone(),
            self.profile_repository.clone(),
            self.model_catalog.clone(),
        )
    }

    pub fn install_fixture_package(&self) -> InstalledAgentProfileReference {
        self.package_installer()
            .install(
                AgentPackageManifest::fixture_valid(),
                LocalBindings::empty().with_credential_ref(
                    "model.account",
                    "credential.openai.default",
                    "sha256:local-binding",
                ),
            )
            .unwrap()
    }
}

impl Default for AgentOsTestWorld {
    fn default() -> Self {
        Self::new()
    }
}
