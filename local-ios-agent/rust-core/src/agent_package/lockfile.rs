use std::collections::BTreeMap;

use crate::agent_package::AgentPackageManifest;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentPackageLock {
    pub schema_version: u32,
    pub package_id: String,
    pub package_content_hash: String,
    pub installed_components: Vec<LockedPackageComponent>,
    pub local_binding_hashes: BTreeMap<String, String>,
    manifest: AgentPackageManifest,
}

impl AgentPackageLock {
    pub fn fixture_installed_profile() -> Self {
        Self {
            schema_version: 1,
            package_id: "agent.fixture".to_string(),
            package_content_hash: "sha256:fixture".to_string(),
            installed_components: vec![LockedPackageComponent {
                component_id: "prompt.identity".to_string(),
                version: "1.0.0".to_string(),
                schema_version: 1,
            }],
            local_binding_hashes: BTreeMap::from([(
                "model.account".to_string(),
                "sha256:local-binding".to_string(),
            )]),
            manifest: AgentPackageManifest::fixture_valid(),
        }
    }

    pub fn fixture_with_component(
        component_id: impl Into<String>,
        version: impl Into<String>,
    ) -> Self {
        let component_id = component_id.into();
        Self {
            schema_version: 1,
            package_id: "agent.fixture".to_string(),
            package_content_hash: "sha256:fixture".to_string(),
            installed_components: vec![LockedPackageComponent {
                component_id,
                version: version.into(),
                schema_version: 1,
            }],
            local_binding_hashes: BTreeMap::new(),
            manifest: AgentPackageManifest::fixture_valid(),
        }
    }

    pub fn manifest(&self) -> &AgentPackageManifest {
        &self.manifest
    }

    pub fn from_installed_manifest(
        manifest: AgentPackageManifest,
        local_binding_hashes: BTreeMap<String, String>,
    ) -> Self {
        Self {
            schema_version: manifest.schema_version,
            package_id: manifest.package_id.clone(),
            package_content_hash: "sha256:pending-package-hash".to_string(),
            installed_components: Vec::new(),
            local_binding_hashes,
            manifest,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LockedPackageComponent {
    pub component_id: String,
    pub version: String,
    pub schema_version: u32,
}
