use std::cmp::Ordering;
use std::collections::BTreeMap;

use crate::agent_package::{AgentPackageLock, PackageError};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ComponentVersionStatus {
    Current,
    UpdateAvailable,
    DowngradeRequired,
    Unavailable,
    IncompatibleSchema,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentUpgradeOperation {
    pub component_id: String,
    pub code: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ComponentUpgradeIssue {
    pub component_id: String,
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AgentProfileUpgradeReport {
    statuses: BTreeMap<String, ComponentVersionStatus>,
    pub operations: Vec<ComponentUpgradeOperation>,
    blocking_issues: Vec<ComponentUpgradeIssue>,
}

impl AgentProfileUpgradeReport {
    pub fn status_for(&self, component_id: &str) -> Option<ComponentVersionStatus> {
        self.statuses.get(component_id).copied()
    }

    pub fn has_blocking_issue(&self, code: &str) -> bool {
        self.blocking_issues.iter().any(|issue| issue.code == code)
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeComponentCatalog {
    components: BTreeMap<String, RuntimeComponentVersion>,
}

impl RuntimeComponentCatalog {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn fixture_with_component(
        component_id: impl Into<String>,
        version: impl Into<String>,
    ) -> Self {
        let component_id = component_id.into();
        Self {
            components: BTreeMap::from([(
                component_id,
                RuntimeComponentVersion {
                    version: version.into(),
                    schema_version: 1,
                },
            )]),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct RuntimeComponentVersion {
    version: String,
    schema_version: u32,
}

#[derive(Clone, Debug, Default)]
pub struct AgentProfileUpgradePlanner;

impl AgentProfileUpgradePlanner {
    pub fn diff_against_runtime_catalog(
        &self,
        lock: &AgentPackageLock,
        runtime_catalog: &RuntimeComponentCatalog,
    ) -> Result<AgentProfileUpgradeReport, PackageError> {
        let mut report = AgentProfileUpgradeReport::default();

        for locked in &lock.installed_components {
            let Some(runtime) = runtime_catalog.components.get(&locked.component_id) else {
                report.statuses.insert(
                    locked.component_id.clone(),
                    ComponentVersionStatus::Unavailable,
                );
                report.blocking_issues.push(ComponentUpgradeIssue {
                    component_id: locked.component_id.clone(),
                    code: "component.runtime.unavailable".to_string(),
                    message: "runtime component is not available on this host".to_string(),
                });
                continue;
            };

            if runtime.schema_version != locked.schema_version {
                report.statuses.insert(
                    locked.component_id.clone(),
                    ComponentVersionStatus::IncompatibleSchema,
                );
                report.blocking_issues.push(ComponentUpgradeIssue {
                    component_id: locked.component_id.clone(),
                    code: "component.schema.incompatible".to_string(),
                    message: "runtime component schema does not match lock".to_string(),
                });
                continue;
            }

            match compare_versions(&runtime.version, &locked.version) {
                Ordering::Equal => {
                    report
                        .statuses
                        .insert(locked.component_id.clone(), ComponentVersionStatus::Current);
                }
                Ordering::Greater => {
                    report.statuses.insert(
                        locked.component_id.clone(),
                        ComponentVersionStatus::UpdateAvailable,
                    );
                    report.operations.push(ComponentUpgradeOperation {
                        component_id: locked.component_id.clone(),
                        code: "component.update.available".to_string(),
                    });
                }
                Ordering::Less => {
                    report.statuses.insert(
                        locked.component_id.clone(),
                        ComponentVersionStatus::DowngradeRequired,
                    );
                    report.operations.push(ComponentUpgradeOperation {
                        component_id: locked.component_id.clone(),
                        code: "component.downgrade.required".to_string(),
                    });
                }
            }
        }

        Ok(report)
    }
}

fn compare_versions(left: &str, right: &str) -> Ordering {
    let left_parts = parse_version(left);
    let right_parts = parse_version(right);
    left_parts.cmp(&right_parts)
}

fn parse_version(value: &str) -> Vec<u64> {
    value
        .split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0))
        .collect()
}
