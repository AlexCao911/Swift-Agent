use crate::{
    llm_contracts::{
        AgentLLMRequirements, LLMInputModality, LLMSlotV2, LLMToolCallingMode,
    },
    storage::{InMemoryTransactionRunner, StorageError},
    user_customization::{
        AgentAssemblyPlan, AgentProfile, AgentProfileDraft, AgentProfileId,
        AgentProfilePublisher, AgentReadinessIssue, AgentReadinessReport, AgentSlotId,
        AgentSlotKind, AgentTemplate, ComponentBinding, ComponentCatalogService, ComponentContent,
        ComponentGraphBuilder, ComponentNode, InMemoryAgentProfileRepository, MissingRequirement,
        UserComponentVersionId, UserFacingCapabilityId, UserProvidedBindings,
    },
};

#[derive(Clone, Debug)]
pub struct AgentBuilderResolver {
    has_persona_component: bool,
    has_model: bool,
    calendar_permission_ready: bool,
    has_web_search_tool: bool,
    component_catalog: ComponentCatalogService,
    persona_version_id: Option<UserComponentVersionId>,
    llm_slot: Option<LLMSlotV2>,
    profile_repository: InMemoryAgentProfileRepository,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentBuilderInput {
    template: AgentTemplate,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserEnvironment {
    tool_bindings_ready: bool,
}

impl AgentBuilderResolver {
    pub fn fixture_missing_model_and_calendar_permission() -> Self {
        Self::fixture(true, false, false, true, CatalogFixtureMode::Registered)
    }

    pub fn fixture_missing_persona_component() -> Self {
        Self::fixture(false, true, true, true, CatalogFixtureMode::Registered)
    }

    pub fn fixture_catalog_without_web_search_tool() -> Self {
        Self::fixture(true, true, true, false, CatalogFixtureMode::Registered)
    }

    pub fn fixture_with_openai_binding_request() -> Self {
        Self::fixture(true, true, true, true, CatalogFixtureMode::Registered)
    }

    pub fn fixture_with_missing_component_catalog_entry() -> Self {
        Self::fixture(
            true,
            true,
            true,
            true,
            CatalogFixtureMode::MissingComponentVersion,
        )
    }

    pub fn fixture_with_missing_model_catalog_entry() -> Self {
        Self::fixture(
            true,
            true,
            true,
            true,
            CatalogFixtureMode::MissingModelSelection,
        )
    }

    fn fixture(
        has_persona_component: bool,
        has_model: bool,
        calendar_permission_ready: bool,
        has_web_search_tool: bool,
        catalog_mode: CatalogFixtureMode,
    ) -> Self {
        let catalog_fixture = CatalogFixture::new(catalog_mode);
        Self {
            has_persona_component,
            has_model,
            calendar_permission_ready,
            has_web_search_tool,
            component_catalog: catalog_fixture.component_catalog,
            persona_version_id: catalog_fixture.persona_version_id,
            llm_slot: catalog_fixture.llm_slot,
            profile_repository: InMemoryAgentProfileRepository::default(),
        }
    }

    pub fn create_plan(
        &self,
        input: AgentBuilderInput,
        environment: &UserEnvironment,
    ) -> Result<AgentAssemblyPlan, AgentBuilderError> {
        let web_search = UserFacingCapabilityId::new("capability.web_search");
        let is_research_template = input.template().id().as_str() == "template.research.assistant";
        let mut graph_builder = ComponentGraphBuilder::default();
        if is_research_template {
            graph_builder = graph_builder
                .add_node(ComponentNode::skill("skill.research", 1).requires(web_search.clone()));
        }
        if is_research_template && self.has_web_search_tool && environment.tool_bindings_ready {
            graph_builder = graph_builder.add_node(
                ComponentNode::tool_recipe("tool.web_search", 2).provides(web_search.clone()),
            );
        }

        let graph = graph_builder.build();
        let capability_report = graph.validate_capabilities();
        let mut plan = AgentAssemblyPlan::new(graph);
        if is_research_template && !capability_report.is_ready() {
            plan = plan
                .missing(MissingRequirement::capability(
                    "skill.research",
                    "capability.web_search",
                ))
                .with_readiness_issue(AgentReadinessIssue::new(
                    "capability.required.missing",
                    "required capability capability.web_search is missing",
                ));
        }

        if input.template.requires_slot(AgentSlotKind::Model) && !self.has_model {
            plan = plan.missing(MissingRequirement::model("slot.model.primary"));
        }

        if input.template.requires_slot(AgentSlotKind::Persona) && !self.has_persona_component {
            plan = plan.with_readiness_issue(AgentReadinessIssue::new(
                "component.persona.missing",
                "required persona component is missing",
            ));
        }

        if self.has_model || self.has_persona_component {
            let profile_draft = profile_draft_for_template(
                input.template(),
                self.has_persona_component,
                self.has_model,
                self.persona_version_id,
                self.llm_slot.clone(),
            );
            plan = self.add_profile_validation_readiness(
                plan,
                profile_draft.clone(),
                input.template(),
            );
            plan = plan.with_profile_draft(profile_draft, input.template().clone());
        }

        plan = self.add_template_readiness(plan, input.template());

        Ok(plan)
    }

    pub fn fixture_plan_with_openai_binding_request(&self) -> AgentAssemblyPlan {
        let web_search = UserFacingCapabilityId::new("capability.web_search");
        let graph = ComponentGraphBuilder::default()
            .add_node(ComponentNode::skill("skill.research", 1).requires(web_search.clone()))
            .add_node(ComponentNode::tool_recipe("tool.web_search", 2).provides(web_search))
            .build();

        let template = AgentTemplate::assistant_default();

        AgentAssemblyPlan::new(graph)
            .with_profile_draft(
                profile_draft_for_template(
                    &template,
                    true,
                    true,
                    self.persona_version_id,
                    self.llm_slot.clone(),
                ),
                template,
            )
    }

    pub fn finalize(
        &self,
        plan: AgentAssemblyPlan,
        _bindings: UserProvidedBindings,
    ) -> Result<AgentProfile, AgentBuilderError> {
        if !plan.readiness_report().is_ready() {
            return Err(AgentBuilderError::new(
                "assembly_plan.not_ready",
                "agent assembly plan still has blocking readiness issues",
            ));
        }

        let (draft, template) = plan.into_profile_draft_and_template().ok_or_else(|| {
            AgentBuilderError::new(
                "assembly_plan.profile_draft_missing",
                "agent assembly plan does not contain a profile draft",
            )
        })?;

        if draft
            .bindings()
            .iter()
            .any(|binding| !binding.component_version_id().is_published())
        {
            return Err(AgentBuilderError::new(
                "component_version.unpublished",
                "finalized profile cannot reference unpublished component versions",
            ));
        }

        let publisher = AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            self.profile_repository.clone(),
        );
        let reference = publisher
            .publish(
                draft,
                &template,
                &self.component_catalog,
            )
            .map_err(AgentBuilderError::from)?;

        self.profile_repository.profile(&reference).ok_or_else(|| {
            AgentBuilderError::new(
                "agent_profile.finalize_missing_published_profile",
                "agent profile publisher did not persist finalized profile",
            )
        })
    }

    pub fn readiness_for_template(&self, template: &AgentTemplate) -> AgentReadinessReport {
        let mut report = AgentReadinessReport::ready();

        if template.requires_slot(AgentSlotKind::Persona) && !self.has_persona_component {
            report.push_issue(AgentReadinessIssue::new(
                "component.persona.missing",
                "required persona component is missing",
            ));
        }

        if template.requires_slot(AgentSlotKind::Model) && !self.has_model {
            report.push_issue(AgentReadinessIssue::new(
                "model.missing",
                "required model binding is missing",
            ));
        }

        if !self.calendar_permission_ready {
            report.push_issue(AgentReadinessIssue::new(
                "permission.calendar.missing",
                "calendar permission is missing",
            ));
        }

        report
    }

    pub fn readiness_for_draft(
        &self,
        draft: &AgentProfileDraft,
        template: &AgentTemplate,
    ) -> AgentReadinessReport {
        let mut report = AgentReadinessReport::ready();

        for slot in template.slots().iter().filter(|slot| slot.is_required()) {
            let satisfied = match slot.kind() {
                AgentSlotKind::Model => draft
                    .llm_slot()
                    .map(|binding| binding.requirements().slot_id() == slot.id().as_str())
                    .unwrap_or(false),
                _ => draft
                    .bindings()
                    .iter()
                    .any(|binding| binding.slot_id() == slot.id()),
            };
            if satisfied {
                continue;
            }

            match slot.kind() {
                AgentSlotKind::Persona => report.push_issue(AgentReadinessIssue::new(
                    "component.persona.missing",
                    "required persona component is missing",
                )),
                AgentSlotKind::Model => report.push_issue(AgentReadinessIssue::new(
                    "model.missing",
                    "required model binding is missing",
                )),
                _ => report.push_issue(AgentReadinessIssue::new(
                    format!("slot.{}.missing", slot.id().as_str()),
                    format!("required slot {} is missing", slot.id().as_str()),
                )),
            }
        }

        if !self.calendar_permission_ready {
            report.push_issue(AgentReadinessIssue::new(
                "permission.calendar.missing",
                "calendar permission is missing",
            ));
        }

        report
    }

    fn add_template_readiness(
        &self,
        mut plan: AgentAssemblyPlan,
        template: &AgentTemplate,
    ) -> AgentAssemblyPlan {
        for issue in self.readiness_for_template(template).issues() {
            if !plan.readiness_report().has_issue(issue.code()) {
                plan = plan.with_readiness_issue(issue.clone());
            }
        }
        plan
    }

    fn add_profile_validation_readiness(
        &self,
        plan: AgentAssemblyPlan,
        draft: AgentProfileDraft,
        template: &AgentTemplate,
    ) -> AgentAssemblyPlan {
        let publisher = AgentProfilePublisher::new(
            Box::new(InMemoryTransactionRunner::default()),
            InMemoryAgentProfileRepository::default(),
        );

        match publisher.publish(
            draft,
            template,
            &self.component_catalog,
        ) {
            Ok(_) => plan,
            Err(error) => plan.with_readiness_issue(AgentReadinessIssue::new(
                error.code().to_string(),
                error.to_string(),
            )),
        }
    }
}

fn fixture_llm_slot() -> LLMSlotV2 {
    LLMSlotV2::new(
        AgentLLMRequirements::new(
            "slot.model.primary",
            4_096,
            true,
            LLMToolCallingMode::Allowed,
        )
        .requiring_input_modality(LLMInputModality::Text),
    )
}

fn profile_draft_for_template(
    template: &AgentTemplate,
    include_persona: bool,
    include_model: bool,
    persona_version_id: Option<UserComponentVersionId>,
    llm_slot: Option<LLMSlotV2>,
) -> AgentProfileDraft {
    let mut draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.fixture.openai"),
        template.id().clone(),
        "Hosted fixture",
    );

    if include_persona && template.supports_slot(AgentSlotKind::Persona) {
        draft = draft.bind(ComponentBinding::persona(
            AgentSlotId::new("slot.persona.primary"),
            persona_version_id.unwrap_or_else(|| UserComponentVersionId::new(1)),
        ));
    }

    if include_model && template.supports_slot(AgentSlotKind::Model) {
        if let Some(slot) = llm_slot {
            draft = draft.with_llm_slot(slot);
        }
    }

    draft
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CatalogFixtureMode {
    Registered,
    MissingComponentVersion,
    MissingModelSelection,
}

struct CatalogFixture {
    component_catalog: ComponentCatalogService,
    persona_version_id: Option<UserComponentVersionId>,
    llm_slot: Option<LLMSlotV2>,
}

impl CatalogFixture {
    fn new(mode: CatalogFixtureMode) -> Self {
        let component_catalog = ComponentCatalogService::default();
        let persona_version_id = if mode == CatalogFixtureMode::MissingComponentVersion {
            Some(UserComponentVersionId::new(99))
        } else {
            let component_id =
                component_catalog.create_draft(ComponentContent::persona("Researcher"));
            Some(
                component_catalog
                    .publish(component_id)
                    .expect("fixture persona component should publish"),
            )
        };

        let llm_slot = if mode == CatalogFixtureMode::MissingModelSelection {
            None
        } else {
            Some(fixture_llm_slot())
        };

        Self {
            component_catalog,
            persona_version_id,
            llm_slot,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentBuilderError {
    code: String,
    message: String,
}

impl AgentBuilderInput {
    pub fn from_template(template: AgentTemplate) -> Self {
        Self { template }
    }

    pub fn template(&self) -> &AgentTemplate {
        &self.template
    }
}

impl UserEnvironment {
    pub fn fixture_ready() -> Self {
        Self {
            tool_bindings_ready: true,
        }
    }

    pub fn fixture_ready_except_tools() -> Self {
        Self {
            tool_bindings_ready: true,
        }
    }
}

impl AgentBuilderError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl From<StorageError> for AgentBuilderError {
    fn from(error: StorageError) -> Self {
        Self::new(error.code().to_string(), error.to_string())
    }
}
