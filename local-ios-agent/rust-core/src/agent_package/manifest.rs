use serde::{Deserialize, Serialize};

use crate::llm_contracts::{
    AgentLLMRequirements, LLMCapabilityRequirement, LLMInputModality, LLMSlotV2, LLMToolCallingMode,
};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AgentPackageManifest {
    pub schema_version: u32,
    pub package_id: String,
    pub name: String,
    pub model_file: Option<String>,
    pub model: Option<PackageModelBinding>,
    #[serde(default)]
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
            schema_version: 1,
            package_id: "agent.fixture".to_string(),
            name: "Fixture Agent".to_string(),
            model_file: Some("model.yaml".to_string()),
            model: Some(PackageModelBinding {
                provider_id: "provider.openai_compatible".to_string(),
                model_id: "gpt-fixture".to_string(),
                credential_ref: None,
                local_path: None,
                unknown_fields: Vec::new(),
            }),
            llm_slot: None,
            package_hash: Some("sha256:fixture".to_string()),
            signature: None,
            unknown_fields: Vec::new(),
        }
    }

    pub fn fixture_with_credential_ref_and_local_path() -> Self {
        Self {
            schema_version: 1,
            package_id: "agent.fixture".to_string(),
            name: "Fixture Agent".to_string(),
            model_file: Some("model.yaml".to_string()),
            model: Some(PackageModelBinding {
                provider_id: "provider.openai_compatible".to_string(),
                model_id: "gpt-fixture".to_string(),
                credential_ref: Some("CredentialRef(openai.account)".to_string()),
                local_path: Some("/Users/alex/.agent/private/model.gguf".to_string()),
                unknown_fields: Vec::new(),
            }),
            llm_slot: None,
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
        if let Some(model_file) = &self.model_file {
            text.push_str(&format!("model_file: {model_file}\n"));
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
        if let Some(model) = &mut scrubbed.model {
            model.credential_ref = None;
            model.local_path = None;
            model.unknown_fields.clear();
        }
        scrubbed
    }

    pub fn translated_for_install(&self) -> Self {
        if self.schema_version != 1 {
            return self.clone();
        }

        let llm_slot = self.model.as_ref().map(|model| {
            let requirements = AgentLLMRequirements::new(
                "slot.model.primary",
                8_192,
                true,
                LLMToolCallingMode::Required,
            )
            .requiring_capability(LLMCapabilityRequirement::new("streaming"))
            .requiring_capability(LLMCapabilityRequirement::new("tool_calling"))
            .requiring_input_modality(LLMInputModality::Text);
            LLMSlotV2::new(requirements).with_model_id_hint(model.model_id.clone())
        });

        Self {
            schema_version: 2,
            package_id: self.package_id.clone(),
            name: self.name.clone(),
            model_file: None,
            model: None,
            llm_slot,
            package_hash: self.package_hash.clone(),
            signature: self.signature.clone(),
            unknown_fields: self.unknown_fields.clone(),
        }
    }
}

impl PackageModelBinding {
    pub fn to_portable_text(&self) -> String {
        let mut text = String::new();
        text.push_str(&format!("provider_id: {}\n", self.provider_id));
        text.push_str(&format!("model_id: {}\n", self.model_id));
        text
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PackageModelBinding {
    pub provider_id: String,
    pub model_id: String,
    pub credential_ref: Option<String>,
    pub local_path: Option<String>,
    #[serde(default)]
    pub unknown_fields: Vec<String>,
}
