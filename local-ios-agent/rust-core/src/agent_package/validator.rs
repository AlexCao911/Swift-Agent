use crate::agent_package::AgentPackageManifest;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageValidationIssue {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PackageValidationReport {
    pub issues: Vec<PackageValidationIssue>,
}

impl PackageValidationReport {
    pub fn add_issue(&mut self, code: impl Into<String>, message: impl Into<String>) {
        self.issues.push(PackageValidationIssue {
            code: code.into(),
            message: message.into(),
        });
    }

    pub fn has_issue(&self, code: &str) -> bool {
        self.issues.iter().any(|issue| issue.code == code)
    }

    pub fn is_valid(&self) -> bool {
        self.issues.is_empty()
    }
}

#[derive(Clone, Debug, Default)]
pub struct AgentPackageValidator;

impl AgentPackageValidator {
    pub fn validate(&self, manifest: &AgentPackageManifest) -> PackageValidationReport {
        let mut report = PackageValidationReport::default();

        if manifest.schema_version == 0 {
            report.add_issue(
                "package.schema_version.invalid",
                "schema_version must be greater than zero",
            );
        }

        if let Some(model) = &manifest.model {
            if model.credential_ref.is_some() {
                report.add_issue(
                    "package.credential_ref.forbidden",
                    "portable package manifests cannot store credential refs",
                );
            }
            if model.local_path.is_some() {
                report.add_issue(
                    "package.local_path.forbidden",
                    "portable package manifests cannot store local paths",
                );
            }
        }

        report
    }
}
