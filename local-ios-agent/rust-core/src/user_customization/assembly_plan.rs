use crate::user_customization::{
    AgentProfileDraft, AgentReadinessIssue, AgentReadinessReport, AgentTemplate, ComponentGraph,
    SafetyReview,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentAssemblyPlan {
    component_graph: ComponentGraph,
    missing_requirements: Vec<MissingRequirement>,
    required_bindings: Vec<BindingRequest>,
    warnings: Vec<AssemblyWarning>,
    safety_review: SafetyReview,
    readiness_report: AgentReadinessReport,
    profile_draft: Option<AgentProfileDraft>,
    profile_template: Option<AgentTemplate>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MissingRequirement {
    code: String,
    slot_id: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BindingRequest {
    provider_id: String,
    binding_key: String,
    kind: BindingRequestKind,
    required: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingRequestKind {
    Credential,
    LocalResource,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssemblyWarning {
    code: String,
    subject: String,
    message: String,
}

impl AgentAssemblyPlan {
    pub fn new(component_graph: ComponentGraph) -> Self {
        Self {
            component_graph,
            missing_requirements: Vec::new(),
            required_bindings: Vec::new(),
            warnings: Vec::new(),
            safety_review: SafetyReview::ready(),
            readiness_report: AgentReadinessReport::ready(),
            profile_draft: None,
            profile_template: None,
        }
    }

    pub fn missing(mut self, missing: MissingRequirement) -> Self {
        self.readiness_report
            .push_issue(missing.to_readiness_issue());
        self.missing_requirements.push(missing);
        self
    }

    pub fn binding(mut self, binding: BindingRequest) -> Self {
        self.required_bindings.push(binding);
        self
    }

    pub fn warning(mut self, warning: AssemblyWarning) -> Self {
        self.warnings.push(warning);
        self
    }

    pub fn with_safety_review(mut self, safety_review: SafetyReview) -> Self {
        self.safety_review = safety_review;
        self
    }

    pub fn with_readiness_issue(mut self, issue: AgentReadinessIssue) -> Self {
        self.readiness_report.push_issue(issue);
        self
    }

    pub(crate) fn with_profile_draft(
        mut self,
        draft: AgentProfileDraft,
        template: AgentTemplate,
    ) -> Self {
        self.profile_draft = Some(draft);
        self.profile_template = Some(template);
        self
    }

    pub(crate) fn into_profile_draft_and_template(
        self,
    ) -> Option<(AgentProfileDraft, AgentTemplate)> {
        Some((self.profile_draft?, self.profile_template?))
    }

    pub fn component_graph(&self) -> &ComponentGraph {
        &self.component_graph
    }

    pub fn missing_requirements(&self) -> &[MissingRequirement] {
        &self.missing_requirements
    }

    pub fn required_bindings(&self) -> &[BindingRequest] {
        &self.required_bindings
    }

    pub fn warnings(&self) -> &[AssemblyWarning] {
        &self.warnings
    }

    pub fn safety_review(&self) -> &SafetyReview {
        &self.safety_review
    }

    pub fn readiness_report(&self) -> &AgentReadinessReport {
        &self.readiness_report
    }
}

impl MissingRequirement {
    pub fn model(slot_id: impl Into<String>) -> Self {
        let slot_id = slot_id.into();
        Self {
            code: "model.missing".to_string(),
            message: format!("required model slot {slot_id} is missing"),
            slot_id,
        }
    }

    pub fn capability(node_id: impl Into<String>, capability: impl Into<String>) -> Self {
        let capability = capability.into();
        Self {
            code: "tool.capability.missing".to_string(),
            slot_id: node_id.into(),
            message: format!("required capability {capability} is missing"),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn slot_id(&self) -> &str {
        &self.slot_id
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    fn to_readiness_issue(&self) -> AgentReadinessIssue {
        AgentReadinessIssue::new(self.code.clone(), self.message.clone())
    }
}

impl BindingRequest {
    pub fn credential(provider_id: impl Into<String>, binding_key: impl Into<String>) -> Self {
        Self {
            provider_id: provider_id.into(),
            binding_key: binding_key.into(),
            kind: BindingRequestKind::Credential,
            required: true,
        }
    }

    pub fn provider_id(&self) -> &str {
        &self.provider_id
    }

    pub fn binding_key(&self) -> &str {
        &self.binding_key
    }

    pub fn kind(&self) -> BindingRequestKind {
        self.kind
    }

    pub fn is_required(&self) -> bool {
        self.required
    }
}

impl AssemblyWarning {
    pub fn requires_approval(subject: impl Into<String>) -> Self {
        let subject = subject.into();
        Self {
            code: "approval.required".to_string(),
            message: format!("{subject} requires user approval"),
            subject,
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }

    pub fn subject(&self) -> &str {
        &self.subject
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}
