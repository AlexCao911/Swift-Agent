use std::sync::Arc;

use crate::model::{
    InMemoryModelBindingCatalog, ModelBindingCatalog, ModelBindingId, ModelCatalogVersion,
    ModelSelection,
};
use crate::run_snapshot::{
    ResolvedRunSnapshot, RunSnapshotError, RunSnapshotResult, RunSnapshotService, StartRunRequest,
};
use crate::security::{
    CredentialPurpose, InMemoryCredentialResolver, PermissionState, StaticSecurityPermissionService,
};
use crate::storage::{
    InMemoryTransactionRunner, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner, UnitOfWork,
};
use crate::user_customization::{
    AgentProfileDraft, AgentProfileId, AgentProfileLocalBindings, AgentProfileModelBinding,
    AgentProfilePublisher, AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService,
    ComponentContent, InMemoryAgentProfileRepository,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentOSApplicationServiceConfig {
    seed_development_profile: bool,
}

pub struct AgentOSApplicationService {
    snapshot_service: RunSnapshotService,
}

struct ModelSelectionStageOperation {
    catalog: InMemoryModelBindingCatalog,
    selection: ModelSelection,
}

impl AgentOSApplicationServiceConfig {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_seed_development_profile(mut self, enabled: bool) -> Self {
        self.seed_development_profile = enabled;
        self
    }

    pub fn seed_development_profile(&self) -> bool {
        self.seed_development_profile
    }
}

impl AgentOSApplicationService {
    pub fn from_config(config: AgentOSApplicationServiceConfig) -> RunSnapshotResult<Self> {
        if config.seed_development_profile() {
            Self::development_seeded()
        } else {
            Ok(Self::empty())
        }
    }

    pub fn empty() -> Self {
        Self {
            snapshot_service: snapshot_service_from_repositories(
                InMemoryAgentProfileRepository::default(),
                ComponentCatalogService::default(),
                InMemoryModelBindingCatalog::default(),
                Arc::new(
                    StaticSecurityPermissionService::default()
                        .with_permission("run.start", PermissionState::Granted),
                ),
                Arc::new(InMemoryCredentialResolver::default()),
            ),
        }
    }

    pub fn resolve_and_persist_snapshot(
        &self,
        request: StartRunRequest,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        self.snapshot_service.resolve_and_persist(request)
    }

    fn development_seeded() -> RunSnapshotResult<Self> {
        let template = AgentTemplate::assistant_default();
        let profile_repository = InMemoryAgentProfileRepository::default();
        let component_catalog = ComponentCatalogService::default();
        let model_catalog = InMemoryModelBindingCatalog::default();

        let persona_component_id =
            component_catalog.create_draft(ComponentContent::persona("Researcher"));
        let persona_version = component_catalog
            .publish(persona_component_id)
            .map_err(|error| {
                RunSnapshotError::new(
                    "application_service.component_publish_failed",
                    error.to_string(),
                )
            })?;

        let model_selection = ModelSelection::new(
            ModelBindingId::new("model_binding.primary"),
            "account.openai.default",
            "provider.openai",
            "gpt-4.1-mini",
            ModelCatalogVersion::new(7),
        );
        stage_model_selection(&model_catalog, model_selection.clone())?;
        let model_catalog_for_publish =
            ModelBindingCatalog::default().with_selection(model_selection.clone());

        let draft = AgentProfileDraft::new(
            AgentProfileId::new("profile_1"),
            template.id().clone(),
            "Development Agent",
        )
        .bind(ComponentBinding::persona(
            template
                .slot_id_for_kind(AgentSlotKind::Persona)
                .expect("assistant template has persona slot")
                .clone(),
            persona_version,
        ))
        .with_model_binding(AgentProfileModelBinding::new(
            template
                .slot_id_for_kind(AgentSlotKind::Model)
                .expect("assistant template has model slot")
                .clone(),
            model_selection,
        ))
        .with_local_bindings(
            AgentProfileLocalBindings::default()
                .with_credential_ref("account.openai.default", "credential.openai.default"),
        );
        AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            profile_repository.clone(),
        )
        .publish(
            draft,
            &template,
            &component_catalog,
            &model_catalog_for_publish,
        )
        .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;

        Ok(Self {
            snapshot_service: snapshot_service_from_repositories(
                profile_repository,
                component_catalog,
                model_catalog,
                Arc::new(
                    StaticSecurityPermissionService::default()
                        .with_permission("run.start", PermissionState::Granted),
                ),
                Arc::new(InMemoryCredentialResolver::default().with_secret_for(
                    "credential.openai.default",
                    "secret",
                    [CredentialPurpose::RemoteProvider],
                )),
            ),
        })
    }
}

impl TransactionOperation for ModelSelectionStageOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        self.catalog.stage(tx, self.selection.clone())
    }
}

fn stage_model_selection(
    catalog: &InMemoryModelBindingCatalog,
    selection: ModelSelection,
) -> RunSnapshotResult<()> {
    let mut operation = ModelSelectionStageOperation {
        catalog: catalog.clone(),
        selection,
    };
    InMemoryTransactionRunner::default()
        .run(
            TransactionName::new("application_service.model_binding.seed"),
            &mut operation,
        )
        .map_err(RunSnapshotError::from)
}

fn snapshot_service_from_repositories(
    profile_repository: InMemoryAgentProfileRepository,
    component_catalog: ComponentCatalogService,
    model_catalog: InMemoryModelBindingCatalog,
    security: Arc<dyn crate::security::SecurityPermissionService>,
    credential_resolver: Arc<dyn crate::security::CredentialRefResolver>,
) -> RunSnapshotService {
    RunSnapshotService::from_real_repositories(
        profile_repository,
        component_catalog,
        model_catalog,
        security,
        credential_resolver,
        Box::new(InMemoryTransactionRunner::default()),
    )
}
