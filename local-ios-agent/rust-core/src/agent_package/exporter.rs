use std::collections::BTreeMap;

use crate::agent_package::{AgentPackageLock, PackageError};

#[derive(Clone, Debug, Default)]
pub struct AgentPackageExporter;

impl AgentPackageExporter {
    pub fn export(&self, profile: &AgentPackageLock) -> Result<ExportedAgentPackage, PackageError> {
        let mut files = BTreeMap::new();
        files.insert(
            "agent.yaml".to_string(),
            profile.manifest().to_portable_text(),
        );

        Ok(ExportedAgentPackage { files })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExportedAgentPackage {
    pub files: BTreeMap<String, String>,
}

impl ExportedAgentPackage {
    pub fn serialized_text(&self) -> String {
        self.files
            .iter()
            .map(|(path, content)| format!("--- {path} ---\n{content}"))
            .collect::<Vec<_>>()
            .join("\n")
    }
}
