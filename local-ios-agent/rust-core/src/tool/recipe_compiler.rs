use std::collections::{BTreeMap, BTreeSet};

use crate::core::AgentError;
use crate::security::{ApprovalRequirement, CredentialPurpose};
use crate::tool::{CompiledToolRecipe, CompiledToolRecipeContent, ToolRecipe, ToolRecipeContent};

const MAX_HTTP_TIMEOUT_MILLIS: u64 = 120_000;
const MAX_HTTP_RETRY_ATTEMPTS: u8 = 5;
const MAX_HTTP_REQUESTS_PER_MINUTE: u16 = 600;

#[derive(Clone, Debug, Default)]
pub struct ToolRecipeCompiler {
    base_tools: BTreeMap<String, ApprovalRequirement>,
}

impl ToolRecipeCompiler {
    pub fn fixture_with_base_tool(
        name: impl Into<String>,
        approval_requirement: ApprovalRequirement,
    ) -> Self {
        let mut base_tools = BTreeMap::new();
        base_tools.insert(name.into(), approval_requirement);
        Self { base_tools }
    }

    pub fn fixture_with_base_tools<I, N>(tools: I) -> Self
    where
        I: IntoIterator<Item = (N, ApprovalRequirement)>,
        N: Into<String>,
    {
        Self {
            base_tools: tools
                .into_iter()
                .map(|(name, approval)| (name.into(), approval))
                .collect(),
        }
    }

    pub fn validate(&self, recipe: &ToolRecipe) -> ToolRecipeValidationReport {
        let mut report = ToolRecipeValidationReport::default();
        match recipe.content() {
            ToolRecipeContent::HttpConnector { endpoint, policy } => {
                match policy.timeout_millis {
                    None => report.push_issue("http.timeout.required"),
                    Some(timeout) if timeout == 0 || timeout > MAX_HTTP_TIMEOUT_MILLIS => {
                        report.push_issue("http.timeout.invalid");
                    }
                    Some(_) => {}
                }
                match &policy.retry_policy {
                    None => report.push_issue("http.retry.required"),
                    Some(retry)
                        if retry.max_attempts == 0
                            || retry.max_attempts > MAX_HTTP_RETRY_ATTEMPTS =>
                    {
                        report.push_issue("http.retry.max_attempts.invalid");
                    }
                    Some(_) => {}
                }
                match &policy.rate_limit_policy {
                    None => report.push_issue("http.rate_limit.required"),
                    Some(rate_limit)
                        if rate_limit.requests_per_minute == 0
                            || rate_limit.requests_per_minute > MAX_HTTP_REQUESTS_PER_MINUTE =>
                    {
                        report.push_issue("http.rate_limit.requests_per_minute.invalid");
                    }
                    Some(_) => {}
                }
                let parsed_endpoint = ParsedHttpsEndpoint::parse(endpoint);
                if parsed_endpoint.is_none() {
                    report.push_issue("http.endpoint.invalid");
                }

                if policy.network_allowlist.is_empty() {
                    report.push_issue("http.network_allowlist.required");
                } else if let Some(parsed_endpoint) = parsed_endpoint {
                    if !policy
                        .network_allowlist
                        .iter()
                        .any(|allowed| allowed.eq_ignore_ascii_case(parsed_endpoint.host.as_str()))
                    {
                        report.push_issue("http.network_allowlist.destination_not_allowed");
                    }
                }
                if policy.data_egress_disclosure.is_none() {
                    report.push_issue("http.egress_disclosure.required");
                }
                if recipe.credential_ref().is_some()
                    && policy.credential_purpose != Some(CredentialPurpose::HttpTool)
                {
                    report.push_issue("http.credential_purpose.required");
                }
                if policy.response_sensitivity.is_none() {
                    report.push_issue("http.response_sensitivity.required");
                }
            }
            ToolRecipeContent::Workflow { steps } => {
                validate_workflow_shape(steps, &mut report);
                if workflow_has_cycle(steps) {
                    report.push_issue("workflow.dag.cycle");
                }
                if self.workflow_compensation_expands_permission(steps) {
                    report.push_issue("workflow.compensation.permission_expansion");
                }
            }
            _ => {}
        }
        report
    }

    pub fn dry_run(&self, recipe: &ToolRecipe) -> ToolRecipeDryRunReport {
        let mut report = ToolRecipeDryRunReport::default();
        match recipe.content() {
            ToolRecipeContent::HttpConnector { endpoint, .. } => {
                report.push_effect("http.request", format!("HTTP request to {endpoint}"));
            }
            ToolRecipeContent::PureTransform { .. } => {
                report.push_effect("pure_transform", "Run pure transform without side effects");
            }
            ToolRecipeContent::Alias { base_tool_name } => {
                report.push_effect("tool.alias", format!("Invoke base tool {base_tool_name}"));
            }
            ToolRecipeContent::Workflow { steps } => {
                for step in steps {
                    report.push_effect(
                        "workflow.step",
                        format!("Invoke workflow step {} using {}", step.id, step.tool_name),
                    );
                }
            }
        }
        report
    }

    pub fn compile(&self, recipe: ToolRecipe) -> Result<CompiledToolRecipe, AgentError> {
        let validation = self.validate(&recipe);
        if !validation.is_valid() {
            return Err(AgentError::ToolValidation(format!(
                "invalid tool recipe: {}",
                validation.issue_codes().join(", ")
            )));
        }

        match recipe.content() {
            ToolRecipeContent::Alias { base_tool_name } => {
                let base_approval = self.base_approval(base_tool_name)?;
                let approval_requirement =
                    strictest_approval(recipe.requested_approval(), base_approval);
                Ok(CompiledToolRecipe {
                    name: recipe.name().to_string(),
                    kind: recipe.kind(),
                    approval_requirement,
                    base_tools: vec![base_tool_name.clone()],
                    has_side_effects: true,
                    content: CompiledToolRecipeContent::Alias {
                        base_tool_name: base_tool_name.clone(),
                    },
                })
            }
            ToolRecipeContent::Workflow { steps } => {
                let mut approval_requirement = recipe
                    .requested_approval()
                    .unwrap_or(ApprovalRequirement::NotRequired);
                let mut base_tools = Vec::with_capacity(steps.len());
                for step in steps {
                    let base_approval = self.base_approval(&step.tool_name)?;
                    approval_requirement =
                        strictest_approval(Some(approval_requirement), base_approval);
                    base_tools.push(step.tool_name.clone());
                }
                Ok(CompiledToolRecipe {
                    name: recipe.name().to_string(),
                    kind: recipe.kind(),
                    approval_requirement,
                    base_tools,
                    has_side_effects: true,
                    content: CompiledToolRecipeContent::Workflow {
                        steps: steps.clone(),
                    },
                })
            }
            ToolRecipeContent::HttpConnector { endpoint, policy } => Ok(CompiledToolRecipe {
                name: recipe.name().to_string(),
                kind: recipe.kind(),
                approval_requirement: recipe
                    .requested_approval()
                    .unwrap_or(ApprovalRequirement::NotRequired),
                base_tools: Vec::new(),
                has_side_effects: true,
                content: CompiledToolRecipeContent::HttpConnector {
                    endpoint: endpoint.clone(),
                    policy: policy.clone(),
                    credential_ref: recipe.credential_ref().cloned(),
                },
            }),
            ToolRecipeContent::PureTransform { expression } => Ok(CompiledToolRecipe {
                name: recipe.name().to_string(),
                kind: recipe.kind(),
                approval_requirement: recipe
                    .requested_approval()
                    .unwrap_or(ApprovalRequirement::NotRequired),
                base_tools: Vec::new(),
                has_side_effects: false,
                content: CompiledToolRecipeContent::PureTransform {
                    expression: expression.clone(),
                },
            }),
        }
    }

    fn base_approval(&self, tool_name: &str) -> Result<ApprovalRequirement, AgentError> {
        self.base_tools.get(tool_name).cloned().ok_or_else(|| {
            AgentError::ToolValidation(format!("unknown base tool in recipe: {tool_name}"))
        })
    }

    fn workflow_compensation_expands_permission(
        &self,
        steps: &[crate::tool::WorkflowStep],
    ) -> bool {
        for step in steps {
            let Some(target_step_id) = &step.compensation_for else {
                continue;
            };
            let Some(target_step) = steps
                .iter()
                .find(|candidate| candidate.id == *target_step_id)
            else {
                continue;
            };
            let Ok(compensation_approval) = self.base_approval(&step.tool_name) else {
                continue;
            };
            let Ok(target_approval) = self.base_approval(&target_step.tool_name) else {
                continue;
            };
            if approval_rank(&compensation_approval) > approval_rank(&target_approval) {
                return true;
            }
        }
        false
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ParsedHttpsEndpoint {
    host: String,
}

impl ParsedHttpsEndpoint {
    fn parse(endpoint: &str) -> Option<Self> {
        let rest = endpoint.strip_prefix("https://")?;
        let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
        let authority = &rest[..authority_end];
        if authority.is_empty() || authority.contains('@') || authority.contains(' ') {
            return None;
        }

        let (host, port) = authority
            .split_once(':')
            .map_or((authority, None), |(host, port)| (host, Some(port)));
        if let Some(port) = port {
            if port.is_empty() || !port.chars().all(|character| character.is_ascii_digit()) {
                return None;
            }
        }

        if host.is_empty()
            || !host.contains('.')
            || host.starts_with('.')
            || host.ends_with('.')
            || host.contains("..")
            || !host.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '-' | '.')
            })
            || host
                .split('.')
                .any(|label| label.is_empty() || label.starts_with('-') || label.ends_with('-'))
        {
            return None;
        }
        Some(Self {
            host: host.to_ascii_lowercase(),
        })
    }
}

fn validate_workflow_shape(
    steps: &[crate::tool::WorkflowStep],
    report: &mut ToolRecipeValidationReport,
) {
    let mut seen = BTreeSet::new();
    let mut duplicate_seen = false;
    for step in steps {
        if !seen.insert(step.id.as_str()) && !duplicate_seen {
            report.push_issue("workflow.step.duplicate_id");
            duplicate_seen = true;
        }
    }

    let step_ids: BTreeSet<_> = steps.iter().map(|step| step.id.as_str()).collect();
    let mut missing_dependency_seen = false;
    for step in steps {
        for dependency in &step.depends_on {
            if !step_ids.contains(dependency.as_str()) && !missing_dependency_seen {
                report.push_issue("workflow.dependency.missing");
                missing_dependency_seen = true;
            }
        }
    }

    for step in steps {
        if step.on_failure == crate::tool::WorkflowFailureStrategy::Compensate
            && !steps
                .iter()
                .any(|candidate| candidate.compensation_for.as_deref() == Some(step.id.as_str()))
        {
            report.push_issue("workflow.compensation.required");
            break;
        }
        if let Some(target) = &step.compensation_for {
            if !step_ids.contains(target.as_str()) {
                report.push_issue("workflow.compensation.target_missing");
                break;
            }
        }
    }
}

fn workflow_has_cycle(steps: &[crate::tool::WorkflowStep]) -> bool {
    let step_ids: BTreeSet<_> = steps.iter().map(|step| step.id.as_str()).collect();
    for step in steps {
        let mut visiting = BTreeSet::new();
        if workflow_visit_has_cycle(step.id.as_str(), steps, &step_ids, &mut visiting) {
            return true;
        }
    }
    false
}

fn workflow_visit_has_cycle<'a>(
    step_id: &'a str,
    steps: &'a [crate::tool::WorkflowStep],
    step_ids: &BTreeSet<&'a str>,
    visiting: &mut BTreeSet<&'a str>,
) -> bool {
    if !visiting.insert(step_id) {
        return true;
    }

    let Some(step) = steps.iter().find(|step| step.id == step_id) else {
        visiting.remove(step_id);
        return false;
    };

    for dependency in &step.depends_on {
        let dependency = dependency.as_str();
        if step_ids.contains(dependency)
            && workflow_visit_has_cycle(dependency, steps, step_ids, visiting)
        {
            return true;
        }
    }

    visiting.remove(step_id);
    false
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ToolRecipeValidationReport {
    issues: Vec<ToolRecipeValidationIssue>,
}

impl ToolRecipeValidationReport {
    pub fn has_issue(&self, code: &str) -> bool {
        self.issues.iter().any(|issue| issue.code == code)
    }

    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }

    pub fn issue_codes(&self) -> Vec<String> {
        self.issues.iter().map(|issue| issue.code.clone()).collect()
    }

    fn push_issue(&mut self, code: impl Into<String>) {
        self.issues
            .push(ToolRecipeValidationIssue { code: code.into() });
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolRecipeValidationIssue {
    pub code: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ToolRecipeDryRunReport {
    effects: Vec<ToolRecipeDryRunEffect>,
}

impl ToolRecipeDryRunReport {
    pub fn effects(&self) -> &[ToolRecipeDryRunEffect] {
        &self.effects
    }

    pub fn has_effect(&self, kind: &str) -> bool {
        self.effects.iter().any(|effect| effect.kind == kind)
    }

    fn push_effect(&mut self, kind: impl Into<String>, description: impl Into<String>) {
        self.effects.push(ToolRecipeDryRunEffect {
            kind: kind.into(),
            description: description.into(),
        });
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolRecipeDryRunEffect {
    pub kind: String,
    pub description: String,
}

fn strictest_approval(
    requested: Option<ApprovalRequirement>,
    inherited: ApprovalRequirement,
) -> ApprovalRequirement {
    if requested == Some(ApprovalRequirement::Required)
        || inherited == ApprovalRequirement::Required
    {
        ApprovalRequirement::Required
    } else {
        ApprovalRequirement::NotRequired
    }
}

fn approval_rank(approval: &ApprovalRequirement) -> u8 {
    match approval {
        ApprovalRequirement::NotRequired => 0,
        ApprovalRequirement::Required => 1,
    }
}
