use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::core::AgentError;
use crate::security::RiskLevel;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolSchema {
    pub name: String,
    pub description: String,
    pub parameters_json_schema: String,
    pub risk_level: RiskLevel,
    pub metadata_json: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments_json: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HostPlatform {
    Ios,
    MacOs,
    Android,
    Windows,
    Linux,
    Web,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolCapabilityDescriptor {
    capability_id: String,
    permission_scope: Option<String>,
    platforms: Vec<HostPlatform>,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolSchemaMetadata {
    capabilities: Vec<ToolCapabilityDescriptor>,
}

impl ToolSchema {
    pub fn with_metadata(mut self, metadata: ToolSchemaMetadata) -> Self {
        self.metadata_json =
            Some(serde_json::to_string(&metadata).expect("tool schema metadata serializes"));
        self
    }

    pub fn typed_metadata(&self) -> Option<ToolSchemaMetadata> {
        self.metadata_json
            .as_deref()
            .and_then(|json| serde_json::from_str(json).ok())
    }

    pub fn provides_capability(&self, capability_id: &str) -> bool {
        self.typed_metadata()
            .map(|metadata| metadata.provides_capability(capability_id))
            .unwrap_or(false)
    }
}

impl ToolCapabilityDescriptor {
    pub fn new(capability_id: impl Into<String>) -> Self {
        Self {
            capability_id: capability_id.into(),
            permission_scope: None,
            platforms: Vec::new(),
        }
    }

    pub fn with_permission_scope(mut self, permission_scope: impl Into<String>) -> Self {
        self.permission_scope = Some(permission_scope.into());
        self
    }

    pub fn available_on(mut self, platform: HostPlatform) -> Self {
        if !self.platforms.contains(&platform) {
            self.platforms.push(platform);
        }
        self
    }

    pub fn capability_id(&self) -> &str {
        &self.capability_id
    }

    pub fn permission_scope(&self) -> Option<&str> {
        self.permission_scope.as_deref()
    }

    pub fn platforms(&self) -> &[HostPlatform] {
        &self.platforms
    }
}

impl ToolSchemaMetadata {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_capability(mut self, capability: ToolCapabilityDescriptor) -> Self {
        self.capabilities.push(capability);
        self
    }

    pub fn capabilities(&self) -> &[ToolCapabilityDescriptor] {
        &self.capabilities
    }

    pub fn provides_capability(&self, capability_id: &str) -> bool {
        self.capabilities
            .iter()
            .any(|capability| capability.capability_id() == capability_id)
    }
}

impl ToolCall {
    pub fn validate_shape(&self) -> Result<(), AgentError> {
        if self.id.trim().is_empty() {
            return Err(AgentError::ToolValidation(
                "tool call id must not be empty".to_string(),
            ));
        }
        if self.name.trim().is_empty() {
            return Err(AgentError::ToolValidation(
                "tool call name must not be empty".to_string(),
            ));
        }

        let arguments: Value = serde_json::from_str(&self.arguments_json).map_err(|error| {
            AgentError::ToolValidation(format!(
                "invalid arguments for tool `{}`: {error}",
                self.name
            ))
        })?;
        if !arguments.is_object() {
            return Err(AgentError::ToolValidation(format!(
                "arguments for tool `{}` must be a JSON object",
                self.name
            )));
        }

        Ok(())
    }
}
