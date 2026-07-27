use serde::{Deserialize, Serialize};

use crate::llm_contracts::{
    AgentLLMRequirements, LLMCapabilityRequirement, LLMInputModality, LLMSlotV2,
    LLMToolCallingMode,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AgentPackageManifest {
    pub schema_version: u32,
    pub package_id: String,
    pub name: String,
    pub llm_slot: Option<LLMSlotV2>,
    #[serde(default)]
    pub package_hash: Option<String>,
    #[serde(default)]
    pub signature: Option<String>,
    #[serde(default)]
    pub unknown_fields: Vec<String>,
}

impl AgentPackageManifest {
    pub fn fixture_valid() -> Self {
        Self {
            schema_version: 2,
            package_id: "agent.fixture".to_string(),
            name: "Fixture Agent".to_string(),
            llm_slot: Some(fixture_llm_slot("gpt-fixture")),
            package_hash: Some("sha256:fixture".to_string()),
            signature: None,
            unknown_fields: Vec::new(),
        }
    }

    pub fn to_portable_text(&self) -> String {
        let mut text = String::new();
        text.push_str(&format!("schema_version: {}\n", self.schema_version));
        text.push_str(&format!("package_id: {}\n", self.package_id));
        text.push_str(&format!("name: {}\n", self.name));
        if let Some(llm_slot) = &self.llm_slot {
            let encoded = serde_json::to_string(llm_slot)
                .expect("portable LLM slot serialization must be infallible");
            text.push_str(&format!("llm_slot_json: {encoded}\n"));
        }
        if let Some(package_hash) = &self.package_hash {
            text.push_str(&format!("package_hash: {package_hash}\n"));
        }
        if let Some(signature) = &self.signature {
            text.push_str(&format!("signature: {signature}\n"));
        }
        text
    }

    pub fn scrubbed_for_lock(&self) -> Self {
        let mut scrubbed = self.clone();
        scrubbed.unknown_fields.clear();
        scrubbed
    }
}

pub(crate) fn fixture_llm_slot(model_id_hint: impl Into<String>) -> LLMSlotV2 {
    let requirements = AgentLLMRequirements::new(
        "slot.model.primary",
        8_192,
        true,
        LLMToolCallingMode::Required,
    )
    .requiring_capability(LLMCapabilityRequirement::new("streaming"))
    .requiring_capability(LLMCapabilityRequirement::new("tool_calling"))
    .requiring_input_modality(LLMInputModality::Text);
    LLMSlotV2::new(requirements).with_model_id_hint(model_id_hint)
}
