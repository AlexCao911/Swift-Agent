use std::sync::Arc;

use crate::llm_contracts::{AgentLLMRequirements, LLMInputModality, LLMSlotV2, LLMToolCallingMode};
use crate::run_snapshot::{RunSnapshotError, RunSnapshotResult, RunSnapshotService};
use crate::storage::{
    InMemoryRuntimeStateStore, InMemoryTransactionRunner, UnifiedRuntimeStateRepository,
};
use crate::user_customization::{
    AgentProfile, AgentProfileDraft, AgentProfileId, AgentProfilePublisher, AgentProfileReference,
    AgentProfileVersion, AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService,
    ComponentContent, InMemoryAgentProfileRepository, ProfilePublicationOperation,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentOSApplicationServiceConfig {
    seed_development_profile: bool,
}

pub struct AgentOSApplicationService {
    snapshot_service: Arc<RunSnapshotService>,
    profile_repository: InMemoryAgentProfileRepository,
    runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
    component_catalog: ComponentCatalogService,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentBuilderCardDraftInput {
    pub display_name: Option<String>,
    pub system_prompt: Option<String>,
    pub persona: Option<String>,
    pub response_style: Option<String>,
    pub selected_tool_ids: Vec<String>,
    pub context_step_ids: Vec<String>,
}

impl AgentBuilderCardDraftInput {
    fn display_name(&self) -> String {
        non_empty_trimmed(&self.display_name).unwrap_or_else(|| "Custom Agent".to_string())
    }

    fn persona_name(&self) -> String {
        non_empty_trimmed(&self.persona).unwrap_or_else(|| self.display_name())
    }

    fn instruction_text(&self) -> Option<String> {
        let mut lines = Vec::new();
        if let Some(system_prompt) = non_empty_trimmed(&self.system_prompt) {
            lines.push(format!("System prompt: {system_prompt}"));
        }
        if let Some(response_style) = non_empty_trimmed(&self.response_style) {
            lines.push(format!("Response style: {response_style}"));
        }
        let context_steps = cleaned_list(&self.context_step_ids);
        if !context_steps.is_empty() {
            lines.push(format!("Context pipeline: {}", context_steps.join(", ")));
        }

        if lines.is_empty() {
            None
        } else {
            Some(lines.join("\n"))
        }
    }

    fn tool_recipe_name(&self) -> Option<String> {
        let tool_ids = cleaned_list(&self.selected_tool_ids);
        if tool_ids.is_empty() {
            None
        } else {
            Some(format!("Selected tools: {}", tool_ids.join(", ")))
        }
    }
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
        Self::from_repositories(
            profile_repository,
            Arc::new(InMemoryRuntimeStateStore::new()),
            component_catalog,
        )
    }

    pub fn from_runtime_state(
        config: AgentOSApplicationServiceConfig,
        runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
    ) -> RunSnapshotResult<Self> {
        if config.seed_development_profile() {
            let seeded = Self::development_seeded()?;
            for profile in seeded.profile_repository.profiles() {
                let components = seeded
                    .component_catalog
                    .published_versions_for(
                        profile
                            .bindings()
                            .iter()
                            .map(ComponentBinding::component_version_id),
                    )
                    .map_err(|error| {
                        RunSnapshotError::new(error.code().to_string(), error.to_string())
                    })?;
                runtime_state
                    .publish_agent_profile_aggregate(ProfilePublicationOperation::new(
                        profile, components,
                    ))
                    .map_err(runtime_state_error)?;
            }
            return Ok(Self::from_repositories(
                seeded.profile_repository,
                runtime_state,
                seeded.component_catalog,
            ));
        }
        let profile_repository = InMemoryAgentProfileRepository::default();
        let component_catalog = ComponentCatalogService::default();
        component_catalog
            .restore_published_versions(
                runtime_state
                    .agent_component_revisions()
                    .map_err(runtime_state_error)?,
            )
            .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;
        let service = Self::from_repositories(
            profile_repository,
            runtime_state,
            component_catalog,
        );
        Ok(service)
    }

    pub fn snapshot_service(&self) -> Arc<RunSnapshotService> {
        self.snapshot_service.clone()
    }

    pub fn profile_repository(&self) -> InMemoryAgentProfileRepository {
        self.profile_repository.clone()
    }

    pub fn runtime_state(&self) -> Arc<dyn UnifiedRuntimeStateRepository> {
        self.runtime_state.clone()
    }

    pub fn list_agent_profiles(&self) -> Vec<AgentProfile> {
        self.runtime_state
            .latest_agent_profiles()
            .unwrap_or_default()
    }

    pub fn build_agent_from_template(
        &self,
        profile_id: Option<&str>,
        template_id: &str,
        card_draft: AgentBuilderCardDraftInput,
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
            if let Some(profile) = self
                .profile_repository
                .profile(&AgentProfileReference::pinned(
                    profile_id.clone(),
                    AgentProfileVersion::initial(),
                ))
            {
                return Ok(profile);
            }
            AgentProfileVersion::initial()
        };

        let display_name = card_draft.display_name();
        let persona_component_id = self
            .component_catalog
            .create_draft(ComponentContent::persona(card_draft.persona_name()));
        let persona_version = self
            .component_catalog
            .publish(persona_component_id)
            .map_err(|error| {
                RunSnapshotError::new(
                    "application_service.component_publish_failed",
                    error.to_string(),
                )
            })?;
        let mut draft = AgentProfileDraft::new(profile_id, template.id().clone(), display_name)
            .bind(ComponentBinding::persona(
                template
                    .slot_id_for_kind(AgentSlotKind::Persona)
                    .expect("assistant template has persona slot")
                    .clone(),
                persona_version,
            ))
            .with_llm_slot(default_llm_slot(&template));

        if let Some(instruction_text) = card_draft.instruction_text() {
            let instruction_component_id = self
                .component_catalog
                .create_draft(ComponentContent::instruction(instruction_text));
            let instruction_version = self
                .component_catalog
                .publish(instruction_component_id)
                .map_err(|error| {
                    RunSnapshotError::new(
                        "application_service.component_publish_failed",
                        error.to_string(),
                    )
                })?;
            draft = draft.bind(ComponentBinding::new(
                template
                    .slot_id_for_kind(AgentSlotKind::Instruction)
                    .expect("assistant template has instruction slot")
                    .clone(),
                AgentSlotKind::Instruction,
                instruction_version,
                Default::default(),
            ));
        }

        if let Some(tool_recipe_name) = card_draft.tool_recipe_name() {
            let tool_component_id = self
                .component_catalog
                .create_draft(ComponentContent::tool_recipe(tool_recipe_name));
            let tool_version =
                self.component_catalog
                    .publish(tool_component_id)
                    .map_err(|error| {
                        RunSnapshotError::new(
                            "application_service.component_publish_failed",
                            error.to_string(),
                        )
                    })?;
            draft = draft.bind(ComponentBinding::new(
                template
                    .slot_id_for_kind(AgentSlotKind::Toolset)
                    .expect("assistant template has toolset slot")
                    .clone(),
                AgentSlotKind::Toolset,
                tool_version,
                Default::default(),
            ));
        }

        let reference = AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            self.profile_repository.clone(),
        )
        .publish_with_version(
            draft,
            profile_version,
            &template,
            &self.component_catalog,
        )
        .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;
        let profile = self.profile_repository.profile(&reference).ok_or_else(|| {
            RunSnapshotError::new(
                "application_service.profile_publish_missing",
                "published agent profile could not be loaded from repository",
            )
        })?;
        self.persist_profile_aggregate(&profile)?;
        Ok(profile)
    }

    pub fn build_agent_v2(
        &self,
        operation_id: &str,
        profile_id: Option<&str>,
        template_id: &str,
        card_draft: AgentBuilderCardDraftInput,
        requirements: AgentLLMRequirements,
    ) -> RunSnapshotResult<AgentProfile> {
        if operation_id.trim().is_empty() {
            return Err(RunSnapshotError::new(
                "application_service.publication_operation_invalid",
                "V2 Agent publication operation ID is empty",
            ));
        }
        if let Some(existing) = self
            .runtime_state
            .agent_profile_for_publication_operation(operation_id)
            .map_err(runtime_state_error)?
        {
            return Ok(existing);
        }
        let template = template_for_build_request(template_id)?;
        let profile_id = AgentProfileId::new(
            profile_id
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| format!("profile.from_template.{template_id}")),
        );
        let profile_version = self
            .runtime_state
            .agent_profile_latest(&profile_id)
            .map_err(runtime_state_error)?
            .map(|profile| AgentProfileVersion::new(profile.version().as_u64() + 1))
            .unwrap_or_else(AgentProfileVersion::initial);
        let expected_slot = template
            .slot_id_for_kind(AgentSlotKind::Model)
            .expect("assistant template has model slot");
        if requirements.slot_id() != expected_slot.as_str() {
            return Err(RunSnapshotError::new(
                "application_service.llm_slot_mismatch",
                "portable LLM requirements do not match the template model slot",
            ));
        }

        let persona_component_id = self
            .component_catalog
            .create_draft(ComponentContent::persona(card_draft.persona_name()));
        let persona_version = self
            .component_catalog
            .publish(persona_component_id)
            .map_err(|error| {
                RunSnapshotError::new(
                    "application_service.component_publish_failed",
                    error.to_string(),
                )
            })?;
        let mut draft =
            AgentProfileDraft::new(profile_id, template.id().clone(), card_draft.display_name())
                .bind(ComponentBinding::persona(
                    template
                        .slot_id_for_kind(AgentSlotKind::Persona)
                        .expect("assistant template has persona slot")
                        .clone(),
                    persona_version,
                ))
                .with_llm_slot(LLMSlotV2::new(requirements));

        if let Some(instruction_text) = card_draft.instruction_text() {
            let component_id = self
                .component_catalog
                .create_draft(ComponentContent::instruction(instruction_text));
            let version = self
                .component_catalog
                .publish(component_id)
                .map_err(|error| {
                    RunSnapshotError::new(
                        "application_service.component_publish_failed",
                        error.to_string(),
                    )
                })?;
            draft = draft.bind(ComponentBinding::new(
                template
                    .slot_id_for_kind(AgentSlotKind::Instruction)
                    .expect("assistant template has instruction slot")
                    .clone(),
                AgentSlotKind::Instruction,
                version,
                Default::default(),
            ));
        }
        if let Some(tool_recipe_name) = card_draft.tool_recipe_name() {
            let component_id = self
                .component_catalog
                .create_draft(ComponentContent::tool_recipe(tool_recipe_name));
            let version = self
                .component_catalog
                .publish(component_id)
                .map_err(|error| {
                    RunSnapshotError::new(
                        "application_service.component_publish_failed",
                        error.to_string(),
                    )
                })?;
            draft = draft.bind(ComponentBinding::new(
                template
                    .slot_id_for_kind(AgentSlotKind::Toolset)
                    .expect("assistant template has toolset slot")
                    .clone(),
                AgentSlotKind::Toolset,
                version,
                Default::default(),
            ));
        }

        let staged = InMemoryAgentProfileRepository::default();
        let reference = AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            staged.clone(),
        )
        .publish_with_version(
            draft,
            profile_version,
            &template,
            &self.component_catalog,
        )
        .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;
        let profile = staged.profile(&reference).ok_or_else(|| {
            RunSnapshotError::new(
                "application_service.profile_publish_missing",
                "staged V2 agent profile could not be loaded",
            )
        })?;
        let components = self
            .component_catalog
            .published_versions_for(
                profile
                    .bindings()
                    .iter()
                    .map(ComponentBinding::component_version_id),
            )
            .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;
        self.runtime_state
            .publish_agent_profile_aggregate(
                ProfilePublicationOperation::new(profile.clone(), components)
                    .with_operation_id(operation_id),
            )
            .map_err(runtime_state_error)?;
        Ok(profile)
    }

    fn persist_profile_aggregate(&self, profile: &AgentProfile) -> RunSnapshotResult<()> {
        let components = self
            .component_catalog
            .published_versions_for(
                profile
                    .bindings()
                    .iter()
                    .map(ComponentBinding::component_version_id),
            )
            .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;
        self.runtime_state
            .publish_agent_profile_aggregate(ProfilePublicationOperation::new(
                profile.clone(),
                components,
            ))
            .map_err(runtime_state_error)?;
        Ok(())
    }

    fn development_seeded() -> RunSnapshotResult<Self> {
        let template = AgentTemplate::assistant_default();
        let profile_repository = InMemoryAgentProfileRepository::default();
        let component_catalog = ComponentCatalogService::default();

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
        .with_llm_slot(default_llm_slot(&template));
        AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            profile_repository.clone(),
        )
        .publish(
            draft,
            &template,
            &component_catalog,
        )
        .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;

        let v2_draft = AgentProfileDraft::new(
            AgentProfileId::new("profile_v2"),
            template.id().clone(),
            "Development Host Slot Agent",
        )
        .bind(ComponentBinding::persona(
            template
                .slot_id_for_kind(AgentSlotKind::Persona)
                .expect("assistant template has persona slot")
                .clone(),
            persona_version,
        ))
        .with_llm_slot(default_llm_slot(&template));
        AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            profile_repository.clone(),
        )
        .publish(
            v2_draft,
            &template,
            &component_catalog,
        )
        .map_err(|error| RunSnapshotError::new(error.code().to_string(), error.to_string()))?;

        let service = Self::from_repositories(
            profile_repository,
            Arc::new(InMemoryRuntimeStateStore::new()),
            component_catalog,
        );
        for profile in service.profile_repository.profiles() {
            service.persist_profile_aggregate(&profile)?;
        }
        Ok(service)
    }

    fn from_repositories(
        profile_repository: InMemoryAgentProfileRepository,
        runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
        component_catalog: ComponentCatalogService,
    ) -> Self {
        Self {
            snapshot_service: Arc::new(snapshot_service_from_repositories(
                runtime_state.clone(),
                profile_repository.clone(),
                component_catalog.clone(),
            )),
            profile_repository,
            runtime_state,
            component_catalog,
        }
    }
}

fn runtime_state_error(error: crate::storage::RuntimeStateError) -> RunSnapshotError {
    RunSnapshotError::new(error.code().to_string(), error.to_string())
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

fn default_llm_slot(template: &AgentTemplate) -> LLMSlotV2 {
    LLMSlotV2::new(
        AgentLLMRequirements::new(
            template
                .slot_id_for_kind(AgentSlotKind::Model)
                .expect("assistant template has model slot")
                .as_str(),
            4_096,
            true,
            LLMToolCallingMode::Allowed,
        )
        .requiring_input_modality(LLMInputModality::Text),
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

fn non_empty_trimmed(value: &Option<String>) -> Option<String> {
    value
        .as_ref()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn cleaned_list(values: &[String]) -> Vec<String> {
    values
        .iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn snapshot_service_from_repositories(
    runtime_state: Arc<dyn UnifiedRuntimeStateRepository>,
    profile_repository: InMemoryAgentProfileRepository,
    component_catalog: ComponentCatalogService,
) -> RunSnapshotService {
    RunSnapshotService::from_unified_repositories(
        runtime_state,
        profile_repository,
        component_catalog,
        Box::new(InMemoryTransactionRunner::default()),
    )
}
