use std::collections::BTreeSet;

use serde::{de::Error as _, Deserialize, Deserializer, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct LLMCapabilityRequirement(String);

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LLMInputModality {
    Text,
    Image,
    Audio,
    Video,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LLMToolCallingMode {
    Disabled,
    Allowed,
    Required,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AgentLLMRequirements {
    slot_id: String,
    #[serde(rename = "capabilities")]
    capability_requirements: BTreeSet<LLMCapabilityRequirement>,
    input_modalities: BTreeSet<LLMInputModality>,
    #[serde(deserialize_with = "deserialize_context_budget")]
    context_budget: String,
    streaming_required: bool,
    tool_calling_mode: LLMToolCallingMode,
}

fn deserialize_context_budget<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    let canonical = !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'))
        && value.parse::<u64>().is_ok();
    if !canonical {
        return Err(D::Error::custom(
            "context_budget must be a canonical unsigned decimal string",
        ));
    }
    Ok(value)
}

impl LLMCapabilityRequirement {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl AgentLLMRequirements {
    pub fn new(
        slot_id: impl Into<String>,
        context_budget: u64,
        streaming_required: bool,
        tool_calling_mode: LLMToolCallingMode,
    ) -> Self {
        Self {
            slot_id: slot_id.into(),
            capability_requirements: BTreeSet::new(),
            input_modalities: BTreeSet::new(),
            context_budget: context_budget.to_string(),
            streaming_required,
            tool_calling_mode,
        }
    }

    pub fn requiring_capability(mut self, requirement: LLMCapabilityRequirement) -> Self {
        self.capability_requirements.insert(requirement);
        self
    }

    pub fn requiring_input_modality(mut self, modality: LLMInputModality) -> Self {
        self.input_modalities.insert(modality);
        self
    }

    pub fn slot_id(&self) -> &str {
        &self.slot_id
    }

    pub fn capability_requirements(&self) -> &BTreeSet<LLMCapabilityRequirement> {
        &self.capability_requirements
    }

    pub fn input_modalities(&self) -> &BTreeSet<LLMInputModality> {
        &self.input_modalities
    }

    pub fn context_budget(&self) -> &str {
        &self.context_budget
    }

    pub fn streaming_required(&self) -> bool {
        self.streaming_required
    }

    pub fn tool_calling_mode(&self) -> LLMToolCallingMode {
        self.tool_calling_mode
    }
}
