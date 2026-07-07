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
    AgentProfile, AgentProfileDraft, AgentProfileId, AgentProfileLocalBindings,
    AgentProfileModelBinding, AgentProfilePublisher, AgentProfileReference, AgentProfileVersion,
    AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService, ComponentContent,
    InMemoryAgentProfileRepository,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentOSApplicationServiceConfig {
    seed_development_profile: bool,
}

pub struct AgentOSApplicationService {
    snapshot_service: Arc<RunSnapshotService>,
    profile_repository: InMemoryAgentProfileRepository,
    component_catalog: ComponentCatalogService,
    model_catalog: InMemoryModelBindingCatalog,
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
        let profile_repository = InMemoryAgentProfileRepository::default();
        let component_catalog = ComponentCatalogService::default();
        let model_catalog = InMemoryModelBindingCatalog::default();
        Self::from_repositories(
            profile_repository,
            component_catalog,
            model_catalog,
            Arc::new(
                StaticSecurityPermissionService::default()
                    .with_permission("run.start", PermissionState::Granted),
            ),
            Arc::new(default_credential_resolver()),
        )
    }

    pub fn snapshot_service(&self) -> Arc<RunSnapshotService> {
        self.snapshot_service.clone()
    }

    pub fn resolve_and_persist_snapshot(
        &self,
        request: StartRunRequest,
    ) -> RunSnapshotResult<ResolvedRunSnapshot> {
        self.snapshot_service.resolve_and_persist(request)
    }

    pub fn list_agent_profiles(&self) -> Vec<AgentProfile> {
        self.profile_repository.latest_profiles()
    }

    pub fn build_agent_from_template(
        &self,
        profile_id: Option<&str>,
        template_id: &str,
    ) -> RunSnapshotResult<AgentProfile> {
        let template = template_for_build_request(template_id)?;
        let explicit_profile_id = profile_id.is_some();
        let profile_id = AgentProfileId::new(
            profile_id
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("profile.from_template.{template_id}")),
        );
        let profile_version = if explicit_profile_id {
            next_profile_version(&self.profile_repository, &profile_id)
        } else {
            if let Some(profile) = self.profile_repository.profile(&AgentProfileReference::pinned(
                profile_id.clone(),
                AgentProfileVersion::initial(),
            )) {
                return Ok(profile);
            }
            AgentProfileVersion::initial()
        };

        let persona_component_id = self
            .component_catalog
            .create_draft(ComponentContent::persona("Custom Agent"));
        let persona_version = self
            .component_catalog
            .publish(persona_component_id)
            .map_err(|error| {
                RunSnapshotError::new(
                    "application_service.component_publish_failed",
                    error.to_string(),
                )
            })?;
        let model_selection = default_model_selection();
        ensure_model_selection(&self.model_catalog, model_selection.clone())?;
        let model_catalog_for_publish =
            ModelBindingCatalog::default().with_selection(model_selection.clone());
        let draft = AgentProfileDraft::new(profile_id, template.id().clone(), "Custom Agent")
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
        let reference = AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            self.profile_repository.clone(),
        )
        .publish_with_version(
            draft,
            profile_version,
            &template,
            &self.component_catalog,
            &model_catalog_for_publish,
        )
        .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;
        self.profile_repository.profile(&reference).ok_or_else(|| {
            RunSnapshotError::new(
                "application_service.profile_publish_missing",
                "published agent profile could not be loaded from repository",
            )
        })
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

        let model_selection = default_model_selection();
        ensure_model_selection(&model_catalog, model_selection.clone())?;
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

        Ok(Self::from_repositories(
            profile_repository,
            component_catalog,
            model_catalog,
            Arc::new(
                StaticSecurityPermissionService::default()
                    .with_permission("run.start", PermissionState::Granted),
            ),
            Arc::new(default_credential_resolver()),
        ))
    }

    fn from_repositories(
        profile_repository: InMemoryAgentProfileRepository,
        component_catalog: ComponentCatalogService,
        model_catalog: InMemoryModelBindingCatalog,
        security: Arc<dyn crate::security::SecurityPermissionService>,
        credential_resolver: Arc<dyn crate::security::CredentialRefResolver>,
    ) -> Self {
        Self {
            snapshot_service: Arc::new(snapshot_service_from_repositories(
                profile_repository.clone(),
                component_catalog.clone(),
                model_catalog.clone(),
                security,
                credential_resolver,
            )),
            profile_repository,
            component_catalog,
            model_catalog,
        }
    }
}

fn next_profile_version(
    repository: &InMemoryAgentProfileRepository,
    profile_id: &AgentProfileId,
) -> AgentProfileVersion {
    let next = repository
        .latest_version(profile_id)
        .map(|version| version.as_u64() + 1)
        .unwrap_or_else(|| AgentProfileVersion::initial().as_u64());
    AgentProfileVersion::new(next)
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

fn ensure_model_selection(
    catalog: &InMemoryModelBindingCatalog,
    selection: ModelSelection,
) -> RunSnapshotResult<()> {
    if catalog.contains_exact_selection(&selection) {
        Ok(())
    } else {
        stage_model_selection(catalog, selection)
    }
}

fn default_model_selection() -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.primary"),
        "account.openai.default",
        "provider.openai",
        "gpt-4.1-mini",
        ModelCatalogVersion::new(7),
    )
}

fn default_credential_resolver() -> InMemoryCredentialResolver {
    InMemoryCredentialResolver::default().with_secret_for(
        "credential.openai.default",
        "secret",
        [CredentialPurpose::RemoteProvider],
    )
}

fn template_for_build_request(template_id: &str) -> RunSnapshotResult<AgentTemplate> {
    match template_id {
        "template_1" | "template.assistant.default" => Ok(AgentTemplate::assistant_default()),
        _ => Err(RunSnapshotError::new(
            "application_service.template_not_found",
            format!("unknown agent template id: {template_id}"),
        )),
    }
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
