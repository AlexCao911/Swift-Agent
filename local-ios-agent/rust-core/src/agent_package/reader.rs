use std::collections::BTreeMap;
use std::fmt;
use std::path::{Component, Path};

use crate::agent_package::{AgentPackageManifest, PackageModelBinding};

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct PackageError {
    code: String,
    message: String,
}

impl PackageError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for PackageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for PackageError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackagePath {
    root: String,
}

impl PackagePath {
    pub fn fixture() -> Self {
        Self {
            root: "fixture-agent".to_string(),
        }
    }

    pub fn root(&self) -> &str {
        &self.root
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInspectReport {
    pub root: String,
    pub files: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub struct AgentPackageReader {
    files: BTreeMap<String, String>,
}

impl AgentPackageReader {
    pub fn fixture_with_file(path: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            files: BTreeMap::from([(path.into(), content.into())]),
        }
    }

    pub fn fixture_with_files<I, P, C>(files: I) -> Self
    where
        I: IntoIterator<Item = (P, C)>,
        P: Into<String>,
        C: Into<String>,
    {
        Self {
            files: files
                .into_iter()
                .map(|(path, content)| (path.into(), content.into()))
                .collect(),
        }
    }

    pub fn inspect(&self, path: &PackagePath) -> Result<PackageInspectReport, PackageError> {
        let mut files = Vec::new();
        for file_path in self.files.keys() {
            files.push(normalize_package_path(file_path)?);
        }

        Ok(PackageInspectReport {
            root: path.root().to_string(),
            files,
        })
    }

    pub fn read_manifest(&self, path: &PackagePath) -> Result<AgentPackageManifest, PackageError> {
        self.inspect(path)?;

        let agent_text = self.files.get("agent.yaml").ok_or_else(|| {
            PackageError::new("package.manifest_missing", "agent.yaml is required")
        })?;
        let agent_map = parse_simple_yaml_map(agent_text)?;
        let schema_version = agent_map
            .get("schema_version")
            .ok_or_else(|| {
                PackageError::new(
                    "package.schema_version.missing",
                    "schema_version is required",
                )
            })?
            .parse::<u32>()
            .map_err(|_| {
                PackageError::new(
                    "package.schema_version.invalid",
                    "schema_version must be an integer",
                )
            })?;
        let package_id = required_field(&agent_map, "package_id")?.to_string();
        let name = required_field(&agent_map, "name")?.to_string();
        let model_file = agent_map.get("model_file").cloned();
        let model = model_file
            .as_ref()
            .map(|model_path| self.read_model_binding(model_path))
            .transpose()?;

        Ok(AgentPackageManifest {
            schema_version,
            package_id,
            name,
            model_file,
            model,
        })
    }

    fn read_model_binding(&self, model_path: &str) -> Result<PackageModelBinding, PackageError> {
        let normalized = normalize_package_path(model_path)?;
        let text = self.files.get(&normalized).ok_or_else(|| {
            PackageError::new("package.required_file_missing", "model file is missing")
        })?;
        let model_map = parse_simple_yaml_map(text)?;
        Ok(PackageModelBinding {
            provider_id: required_field(&model_map, "provider_id")?.to_string(),
            model_id: required_field(&model_map, "model_id")?.to_string(),
            credential_ref: model_map.get("credential_ref").cloned(),
            local_path: model_map.get("local_path").cloned(),
        })
    }
}

fn normalize_package_path(path: &str) -> Result<String, PackageError> {
    let path = Path::new(path);
    if path.is_absolute() {
        return Err(PackageError::new(
            "package.path_absolute",
            "package paths must be relative",
        ));
    }

    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => {
                let value = part.to_string_lossy();
                if is_hidden_runtime_state_dir(&value) {
                    return Err(PackageError::new(
                        "package.runtime_state_path",
                        "package paths cannot point at hidden runtime state",
                    ));
                }
                parts.push(value.to_string());
            }
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(PackageError::new(
                    "package.path_traversal",
                    "package paths cannot traverse outside the package root",
                ));
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(PackageError::new(
                    "package.path_absolute",
                    "package paths must be relative",
                ));
            }
        }
    }

    if parts.is_empty() {
        return Err(PackageError::new(
            "package.path_empty",
            "package path cannot be empty",
        ));
    }

    Ok(parts.join("/"))
}

fn is_hidden_runtime_state_dir(value: &str) -> bool {
    matches!(
        value,
        ".agent-os" | ".agent" | ".git" | "runs" | "run-history" | "memory-data"
    )
}

fn parse_simple_yaml_map(text: &str) -> Result<BTreeMap<String, String>, PackageError> {
    let mut map = BTreeMap::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if line.starts_with(' ') {
            return Err(PackageError::new(
                "package.yaml.unsupported",
                "nested yaml is not supported by the lightweight package reader",
            ));
        }
        let Some((key, value)) = trimmed.split_once(':') else {
            return Err(PackageError::new(
                "package.yaml.invalid",
                "yaml line must contain a key/value pair",
            ));
        };
        map.insert(key.trim().to_string(), value.trim().to_string());
    }
    Ok(map)
}

fn required_field<'a>(
    map: &'a BTreeMap<String, String>,
    key: &str,
) -> Result<&'a str, PackageError> {
    map.get(key)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            PackageError::new(
                format!("package.{key}.missing"),
                format!("{key} is required"),
            )
        })
}
