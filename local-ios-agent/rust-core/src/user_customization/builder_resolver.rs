use crate::{
    model::{ModelBindingId, ModelCatalogVersion, ModelSelection},
    user_customization::{
        AgentAssemblyPlan, AgentProfile, AgentProfileDraft, AgentProfileId,
        AgentProfileModelBinding, AgentReadinessIssue, AgentReadinessReport, AgentSlotId,
        AgentSlotKind, AgentTemplate, BindingRequest, ComponentBinding, ComponentGraphBuilder,
        ComponentNode, MissingRequirement, UserComponentVersionId, UserFacingCapabilityId,
        UserProvidedBindings,
    },
};

#[derive(Clone, Debug)]
pub struct AgentBuilderResolver {
    has_persona_component: bool,
    has_model: bool,
    calendar_permission_ready: bool,
    has_web_search_tool: bool,
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
        Self {
            has_persona_component: true,
            has_model: false,
            calendar_permission_ready: false,
            has_web_search_tool: true,
        }
    }

    pub fn fixture_missing_persona_component() -> Self {
        Self {
            has_persona_component: false,
            has_model: true,
            calendar_permission_ready: true,
            has_web_search_tool: true,
        }
    }

    pub fn fixture_catalog_without_web_search_tool() -> Self {
        Self {
            has_persona_component: true,
            has_model: true,
            calendar_permission_ready: true,
            has_web_search_tool: false,
        }
    }

    pub fn fixture_with_openai_binding_request() -> Self {
        Self {
            has_persona_component: true,
            has_model: true,
            calendar_permission_ready: true,
            has_web_search_tool: true,
        }
    }

    pub fn create_plan(
        &self,
        input: AgentBuilderInput,
        environment: &UserEnvironment,
    ) -> Result<AgentAssemblyPlan, AgentBuilderError> {
        let web_search = UserFacingCapabilityId::new("capability.web_search");
        let mut graph_builder = ComponentGraphBuilder::default()
            .add_node(ComponentNode::skill("skill.research", 1).requires(web_search.clone()));
        if self.has_web_search_tool && environment.tool_bindings_ready {
            graph_builder = graph_builder.add_node(
                ComponentNode::tool_recipe("tool.web_search", 2).provides(web_search.clone()),
            );
        }

        let graph = graph_builder.build();
        let capability_report = graph.validate_capabilities();
        let mut plan = AgentAssemblyPlan::new(graph);
        if !capability_report.is_ready() {
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

        if input.template.supports_slot(AgentSlotKind::Model) && self.has_model {
            plan = plan.binding(BindingRequest::credential(
                "provider.openai",
                "credential.openai.api_key",
            ));
        }

        if self.has_model || self.has_persona_component {
            plan = plan.with_profile_draft(profile_draft_for_template(
                input.template(),
                self.has_persona_component,
                self.has_model,
            ));
        }

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
            .binding(BindingRequest::credential(
                "provider.openai",
                "credential.openai.api_key",
            ))
            .with_profile_draft(profile_draft_for_template(&template, true, true))
    }

    pub fn finalize(
        &self,
        plan: AgentAssemblyPlan,
        bindings: UserProvidedBindings,
    ) -> Result<AgentProfile, AgentBuilderError> {
        if !plan.readiness_report.is_ready() {
            return Err(AgentBuilderError::new(
                "assembly_plan.not_ready",
                "agent assembly plan still has blocking readiness issues",
            ));
        }

        for request in &plan.required_bindings {
            if request.is_required() && bindings.credential_ref(request.binding_key()).is_none() {
                return Err(AgentBuilderError::new(
                    "binding.required.unresolved",
                    format!(
                        "required binding {} has not been provided",
                        request.binding_key()
                    ),
                ));
            }
        }

        let draft = plan.into_profile_draft().ok_or_else(|| {
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

        Ok(draft
            .with_local_bindings(bindings.into_local_bindings())
            .into_published())
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
                    .model_binding()
                    .map(|binding| binding.slot_id() == slot.id())
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
}

fn openai_fixture_model_selection() -> ModelSelection {
    ModelSelection::new(
        ModelBindingId::new("model_binding.openai.default"),
        "credential.openai.api_key",
        "provider.openai",
        "gpt-4.1-mini",
        ModelCatalogVersion::new(1),
    )
}

fn profile_draft_for_template(
    template: &AgentTemplate,
    include_persona: bool,
    include_model: bool,
) -> AgentProfileDraft {
    let mut draft = AgentProfileDraft::new(
        AgentProfileId::new("profile.fixture.openai"),
        template.id().clone(),
        "OpenAI fixture",
    );

    if include_persona && template.supports_slot(AgentSlotKind::Persona) {
        draft = draft.bind(ComponentBinding::persona(
            AgentSlotId::new("slot.persona.primary"),
            UserComponentVersionId::new(1),
        ));
    }

    if include_model && template.supports_slot(AgentSlotKind::Model) {
        draft = draft.with_model_binding(AgentProfileModelBinding::new(
            AgentSlotId::new("slot.model.primary"),
            openai_fixture_model_selection(),
        ));
    }

    draft
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
