use crate::agent_package::{reader::normalize_package_path, AgentPackageManifest};

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
        if let Some(model_file) = &manifest.model_file {
            if normalize_package_path(model_file).is_err() {
                report.add_issue(
                    "package.model_file.path_invalid",
                    "model_file must be a normalized package-relative path",
                );
            }
            if manifest.model.is_none() {
                report.add_issue(
                    "package.model_file.model_missing",
                    "model_file requires a model manifest",
                );
            }
        }
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

        if let Some(model) = &manifest.model {
            if !model.unknown_fields.is_empty() {
                report.add_issue(
                    "package.unknown_field.forbidden",
                    "model manifest contains unknown fields",
                );
            }
            if contains_secret_like_value(&model.provider_id)
                || contains_secret_like_value(&model.model_id)
                || model
                    .credential_ref
                    .as_deref()
                    .is_some_and(contains_secret_like_value)
                || model
                    .local_path
                    .as_deref()
                    .is_some_and(contains_secret_like_value)
            {
                report.add_issue(
                    "package.secret_value.forbidden",
                    "portable package manifests cannot store secret-like values",
                );
            }
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

fn contains_secret_like_value(value: &str) -> bool {
    let value = value.to_ascii_lowercase();
    value.contains("credentialref")
        || value.contains("secret")
        || value.starts_with("sk-")
        || value.contains("api_key")
        || value.contains("token=")
}
