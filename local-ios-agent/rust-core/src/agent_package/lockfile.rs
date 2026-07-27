use crate::agent_package::AgentPackageManifest;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentPackageLock {
    pub schema_version: u32,
    pub package_id: String,
    pub package_content_hash: String,
    pub installed_components: Vec<LockedPackageComponent>,
    manifest: AgentPackageManifest,
}

impl AgentPackageLock {
    pub fn fixture_installed_profile() -> Self {
        Self {
            schema_version: 2,
            package_id: "agent.fixture".to_string(),
            package_content_hash: "sha256:fixture".to_string(),
            installed_components: vec![LockedPackageComponent {
                component_id: "prompt.identity".to_string(),
                version: "1.0.0".to_string(),
                schema_version: 1,
            }],
            manifest: AgentPackageManifest::fixture_valid(),
        }
    }

    pub fn fixture_with_component(
        component_id: impl Into<String>,
        version: impl Into<String>,
    ) -> Self {
        let component_id = component_id.into();
        Self {
            schema_version: 2,
            package_id: "agent.fixture".to_string(),
            package_content_hash: "sha256:fixture".to_string(),
            installed_components: vec![LockedPackageComponent {
                component_id,
                version: version.into(),
                schema_version: 1,
            }],
            manifest: AgentPackageManifest::fixture_valid(),
        }
    }

    pub fn manifest(&self) -> &AgentPackageManifest {
        &self.manifest
    }

    pub fn from_installed_manifest(manifest: AgentPackageManifest) -> Self {
        let manifest = manifest.scrubbed_for_lock();
        Self {
            schema_version: manifest.schema_version,
            package_id: manifest.package_id.clone(),
            package_content_hash: "sha256:pending-package-hash".to_string(),
            installed_components: Vec::new(),
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
