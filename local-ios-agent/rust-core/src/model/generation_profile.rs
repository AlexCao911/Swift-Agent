use crate::model::{ModelCapabilities, ModelProviderIssue};

#[derive(Clone, Debug, PartialEq)]
pub enum ReasoningEffort {
    Low,
    Medium,
    High,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GenerationProfile {
    pub model_id: String,
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
    pub max_output_tokens: Option<u32>,
    pub reasoning_effort: Option<ReasoningEffort>,
}

impl GenerationProfile {
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            temperature: None,
            top_p: None,
            max_output_tokens: None,
            reasoning_effort: None,
        }
    }

    pub fn with_temperature(mut self, temperature: f32) -> Self {
        self.temperature = Some(temperature);
        self
    }

    pub fn with_top_p(mut self, top_p: f32) -> Self {
        self.top_p = Some(top_p);
        self
    }

    pub fn with_max_output_tokens(mut self, max_output_tokens: u32) -> Self {
        self.max_output_tokens = Some(max_output_tokens);
        self
    }

    pub fn with_reasoning_effort(mut self, reasoning_effort: ReasoningEffort) -> Self {
        self.reasoning_effort = Some(reasoning_effort);
        self
    }

    pub fn validate_against(
        &self,
        capabilities: &ModelCapabilities,
    ) -> GenerationProfileValidationReport {
        let mut report = GenerationProfileValidationReport::valid();

        if self.temperature.is_some() && !capabilities.supports_temperature {
            report.add_issue(
                "generation.temperature.unsupported",
                "model does not support temperature",
            );
        }
        if self.top_p.is_some() && !capabilities.supports_top_p {
            report.add_issue(
                "generation.top_p.unsupported",
                "model does not support top_p",
            );
        }
        if self.max_output_tokens.is_some() && !capabilities.supports_max_output_tokens {
            report.add_issue(
                "generation.max_output_tokens.unsupported",
                "model does not support max_output_tokens",
            );
        }
        if self.reasoning_effort.is_some() && !capabilities.supports_reasoning_effort {
            report.add_issue(
                "generation.reasoning_effort.unsupported",
                "model does not support reasoning_effort",
            );
        }

        report
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GenerationProfileValidationReport {
    pub issues: Vec<ModelProviderIssue>,
}

impl GenerationProfileValidationReport {
    pub fn valid() -> Self {
        Self { issues: Vec::new() }
    }

    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }

    fn add_issue(&mut self, code: impl Into<String>, message: impl Into<String>) {
        self.issues.push(ModelProviderIssue::new(code, message));
    }
}
