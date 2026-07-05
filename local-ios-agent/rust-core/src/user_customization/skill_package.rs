use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::context::{ContextContribution, ContextContributionBundle, ContextSegment};
use crate::core::AgentError;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SkillPackageManifest {
    id: String,
    version: String,
    title: String,
    description: String,
    required_capabilities: Vec<String>,
    allowed_capabilities: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillPackage {
    manifest: SkillPackageManifest,
    instructions_markdown: String,
    sandbox_policy: SkillSandboxPolicy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillSandboxPolicy {
    allow_executable_code: bool,
    allowed_capabilities: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillActivationInput {
    run_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SkillActivation {
    skill_id: String,
    reason: String,
    context_contributions: ContextContributionBundle,
}

pub trait SkillRepository {
    fn install(&mut self, package: SkillPackage) -> Result<(), AgentError>;
    fn get(&self, skill_id: &str) -> Option<SkillPackage>;
    fn list(&self) -> Vec<SkillPackage>;
}

#[derive(Clone, Debug, Default)]
pub struct InMemorySkillRepository {
    packages: BTreeMap<String, SkillPackage>,
}

impl SkillPackageManifest {
    pub fn new(
        id: impl Into<String>,
        version: impl Into<String>,
        title: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            version: version.into(),
            title: title.into(),
            description: String::new(),
            required_capabilities: Vec::new(),
            allowed_capabilities: Vec::new(),
        }
    }

    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        self.description = description.into();
        self
    }

    pub fn requires_capability(mut self, capability: impl Into<String>) -> Self {
        self.required_capabilities.push(capability.into());
        self
    }

    pub fn allows_capability(mut self, capability: impl Into<String>) -> Self {
        self.allowed_capabilities.push(capability.into());
        self
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn version(&self) -> &str {
        &self.version
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    pub fn description(&self) -> &str {
        &self.description
    }

    pub fn required_capabilities(&self) -> &[String] {
        &self.required_capabilities
    }

    pub fn allowed_capabilities(&self) -> &[String] {
        &self.allowed_capabilities
    }
}

impl SkillPackage {
    pub fn new(manifest: SkillPackageManifest, instructions_markdown: impl Into<String>) -> Self {
        let mut allowed_capabilities = manifest.required_capabilities.clone();
        for capability in &manifest.allowed_capabilities {
            if !allowed_capabilities.contains(capability) {
                allowed_capabilities.push(capability.clone());
            }
        }

        Self {
            manifest,
            instructions_markdown: instructions_markdown.into(),
            sandbox_policy: SkillSandboxPolicy::data_only(allowed_capabilities),
        }
    }

    pub fn manifest(&self) -> &SkillPackageManifest {
        &self.manifest
    }

    pub fn instructions_markdown(&self) -> &str {
        &self.instructions_markdown
    }

    pub fn sandbox_policy(&self) -> &SkillSandboxPolicy {
        &self.sandbox_policy
    }

    pub fn activate(&self, input: SkillActivationInput) -> SkillActivation {
        let segment_id = format!("skill.{}.instructions", self.manifest.id());
        let contribution = ContextContribution::new(
            self.manifest.id(),
            ContextSegment::skill_instruction(segment_id, self.instructions_markdown.clone())
                .with_provenance(format!("skill:{}:{}", self.manifest.id(), input.run_id())),
        );

        SkillActivation {
            skill_id: self.manifest.id.clone(),
            reason: "skill.activation.manual".to_string(),
            context_contributions: ContextContributionBundle::new().with_contribution(contribution),
        }
    }
}

impl SkillSandboxPolicy {
    pub fn data_only(allowed_capabilities: Vec<String>) -> Self {
        Self {
            allow_executable_code: false,
            allowed_capabilities,
        }
    }

    pub fn allows_executable_code(&self) -> bool {
        self.allow_executable_code
    }

    pub fn allows_capability(&self, capability: &str) -> bool {
        self.allowed_capabilities
            .iter()
            .any(|allowed| allowed == capability)
    }
}

impl SkillActivationInput {
    pub fn new(run_id: impl Into<String>) -> Self {
        Self {
            run_id: run_id.into(),
        }
    }

    pub fn run_id(&self) -> &str {
        &self.run_id
    }
}

impl SkillActivation {
    pub fn skill_id(&self) -> &str {
        &self.skill_id
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }

    pub fn context_contributions(&self) -> &ContextContributionBundle {
        &self.context_contributions
    }
}

impl SkillRepository for InMemorySkillRepository {
    fn install(&mut self, package: SkillPackage) -> Result<(), AgentError> {
        let id = package.manifest().id().to_string();
        if self.packages.contains_key(&id) {
            return Err(AgentError::PolicyDenied(format!(
                "skill package already installed: {id}"
            )));
        }
        self.packages.insert(id, package);
        Ok(())
    }

    fn get(&self, skill_id: &str) -> Option<SkillPackage> {
        self.packages.get(skill_id).cloned()
    }

    fn list(&self) -> Vec<SkillPackage> {
        self.packages.values().cloned().collect()
    }
}
