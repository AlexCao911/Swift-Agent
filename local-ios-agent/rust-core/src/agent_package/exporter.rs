use std::collections::BTreeMap;

use crate::agent_package::{reader::normalize_package_path, AgentPackageLock, PackageError};

#[derive(Clone, Debug, Default)]
pub struct AgentPackageExporter;

impl AgentPackageExporter {
    pub fn export(&self, profile: &AgentPackageLock) -> Result<ExportedAgentPackage, PackageError> {
        let mut files = BTreeMap::new();
        files.insert(
            "agent.yaml".to_string(),
            profile.manifest().to_portable_text(),
        );
        if let (Some(model_file), Some(model)) = (
            profile.manifest().model_file.as_ref(),
            profile.manifest().model.as_ref(),
        ) {
            files.insert(
                normalize_package_path(model_file)?,
                model.to_portable_text(),
            );
        }

        for path in files.keys() {
            normalize_package_path(path)?;
        }

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
