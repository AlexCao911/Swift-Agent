use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct AgentPackageManifest {
    pub schema_version: u32,
    pub package_id: String,
    pub name: String,
    pub model_file: Option<String>,
    pub model: Option<PackageModelBinding>,
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
            }),
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
            }),
        }
    }

    pub fn to_portable_text(&self) -> String {
        let mut text = String::new();
        text.push_str(&format!("schema_version: {}\n", self.schema_version));
        text.push_str(&format!("package_id: {}\n", self.package_id));
        text.push_str(&format!("name: {}\n", self.name));
        if let Some(model_file) = &self.model_file {
            text.push_str(&format!("model_file: {model_file}\n"));
        }
        if let Some(model) = &self.model {
            text.push_str("model:\n");
            text.push_str(&format!("  provider_id: {}\n", model.provider_id));
            text.push_str(&format!("  model_id: {}\n", model.model_id));
        }
        text
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PackageModelBinding {
    pub provider_id: String,
    pub model_id: String,
    pub credential_ref: Option<String>,
    pub local_path: Option<String>,
}
