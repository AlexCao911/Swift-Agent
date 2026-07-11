use serde::{Deserialize, Serialize};

use super::AgentLLMRequirements;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LLMBindingSchema {
    LegacyV1,
    HostSlotV2,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LLMSlotV2 {
    requirements: AgentLLMRequirements,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_family_hint: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_id_hint: Option<String>,
}

impl LLMSlotV2 {
    pub fn new(requirements: AgentLLMRequirements) -> Self {
        Self {
            requirements,
            model_family_hint: None,
            model_id_hint: None,
        }
    }

    pub fn with_model_family_hint(mut self, hint: impl Into<String>) -> Self {
        self.model_family_hint = Some(hint.into());
        self
    }

    pub fn with_model_id_hint(mut self, hint: impl Into<String>) -> Self {
        self.model_id_hint = Some(hint.into());
        self
    }

    pub fn requirements(&self) -> &AgentLLMRequirements {
        &self.requirements
    }

    pub fn model_family_hint(&self) -> Option<&str> {
        self.model_family_hint.as_deref()
    }

    pub fn model_id_hint(&self) -> Option<&str> {
        self.model_id_hint.as_deref()
    }
}
