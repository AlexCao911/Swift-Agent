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

        if manifest.schema_version != 2 {
            report.add_issue(
                "package.schema_version.invalid",
                "production package manifests must use schema_version 2",
            );
        }
        if manifest.package_id.trim().is_empty() {
            report.add_issue("package.package_id.missing", "package_id is required");
        }
        if manifest.name.trim().is_empty() {
            report.add_issue("package.name.missing", "name is required");
        }
        if !manifest.unknown_fields.is_empty() {
            report.add_issue(
                "package.unknown_field.forbidden",
                "package manifest contains unknown fields",
            );
        }
        if contains_secret_like_value(&manifest.package_id)
            || contains_secret_like_value(&manifest.name)
        {
            report.add_issue(
                "package.secret_value.forbidden",
                "portable package manifests cannot store secret-like values",
            );
        }
        if let Some(package_hash) = &manifest.package_hash {
            if !package_hash.starts_with("sha256:") {
                report.add_issue(
                    "package.hash.invalid",
                    "package hash metadata must use sha256",
                );
            }
        }
        validate_v2_slot(manifest, &mut report);
        if manifest.signature.is_some() {
            report.add_issue(
                "package.signature.unsupported",
                "signature verification is not available in this v1 package installer",
            );
        }
        if manifest.signature.is_some() && manifest.package_hash.is_none() {
            report.add_issue(
                "package.signature.hash_required",
                "signature metadata requires package hash metadata",
            );
        }
        report
    }
}

fn validate_v2_slot(manifest: &AgentPackageManifest, report: &mut PackageValidationReport) {
    if manifest.llm_slot.is_none() {
        report.add_issue(
            "package.llm_slot.required",
            "schema-v2 packages must contain a portable LLM slot",
        );
    }
}

fn contains_secret_like_value(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    value.contains("credentialref")
        || value.contains("secret")
        || value.starts_with("sk-")
        || value.contains(concat!("api", "_key"))
        || value.contains("token=")
}
