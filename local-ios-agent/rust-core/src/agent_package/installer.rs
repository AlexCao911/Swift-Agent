use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::agent_package::{AgentPackageLock, AgentPackageManifest};
use crate::storage::{
    StorageResult, TransactionName, TransactionOperation, TransactionRunner, UnitOfWork,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LocalBindings {
    binding_hashes: BTreeMap<String, String>,
}

impl LocalBindings {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn binding_hashes(&self) -> &BTreeMap<String, String> {
        &self.binding_hashes
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallationRecord {
    pub package_id: String,
    pub schema_version: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstalledAgentProfile {
    pub profile_id: String,
    pub package_id: String,
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryPackageInstallStore {
    inner: Arc<Mutex<PackageInstallRecords>>,
}

impl InMemoryPackageInstallStore {
    pub fn apply(&self, commit: PackageInstallCommit) {
        let mut inner = self
            .inner
            .lock()
            .expect("package install store mutex poisoned");
        inner.installations.push(commit.installation);
        inner.agent_profiles.push(commit.profile);
        inner.package_locks.push(commit.lock);
    }

    pub fn installations(&self) -> Vec<PackageInstallationRecord> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .installations
            .clone()
    }

    pub fn agent_profiles(&self) -> Vec<InstalledAgentProfile> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .agent_profiles
            .clone()
    }

    pub fn package_locks(&self) -> Vec<AgentPackageLock> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .package_locks
            .clone()
    }
}

#[derive(Clone, Debug, Default)]
struct PackageInstallRecords {
    installations: Vec<PackageInstallationRecord>,
    agent_profiles: Vec<InstalledAgentProfile>,
    package_locks: Vec<AgentPackageLock>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallCommit {
    installation: PackageInstallationRecord,
    profile: InstalledAgentProfile,
    lock: AgentPackageLock,
}

pub struct AgentPackageInstaller {
    runner: Box<dyn TransactionRunner>,
    store: InMemoryPackageInstallStore,
}

impl AgentPackageInstaller {
    pub fn new(runner: Box<dyn TransactionRunner>, store: InMemoryPackageInstallStore) -> Self {
        Self { runner, store }
    }

    pub fn install(
        &self,
        manifest: AgentPackageManifest,
        bindings: LocalBindings,
    ) -> StorageResult<InstalledAgentProfile> {
        let mut operation = PackageInstallOperation {
            manifest,
            bindings,
            result: None,
        };

        self.runner.run(
            TransactionName::new("agent_package.install"),
            &mut operation,
        )?;

        let commit = operation
            .result
            .expect("package install operation must set typed result on success");
        let profile = commit.profile.clone();
        self.store.apply(commit);
        Ok(profile)
    }

    pub fn preview(&self, manifest: &AgentPackageManifest) -> PackageInstallPreview {
        PackageInstallPreview {
            package_id: manifest.package_id.clone(),
            operations: vec![
                PackageInstallPreviewOperation {
                    code: "package.install.record.create".to_string(),
                },
                PackageInstallPreviewOperation {
                    code: "package.install.profile.create".to_string(),
                },
                PackageInstallPreviewOperation {
                    code: "package.install.lock.create".to_string(),
                },
            ],
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallPreview {
    pub package_id: String,
    pub operations: Vec<PackageInstallPreviewOperation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallPreviewOperation {
    pub code: String,
}

struct PackageInstallOperation {
    manifest: AgentPackageManifest,
    bindings: LocalBindings,
    result: Option<PackageInstallCommit>,
}

impl TransactionOperation for PackageInstallOperation {
    fn execute(&mut self, _tx: &mut UnitOfWork) -> StorageResult<()> {
        let profile = InstalledAgentProfile {
            profile_id: format!("profile:{}", self.manifest.package_id),
            package_id: self.manifest.package_id.clone(),
        };
        self.result = Some(PackageInstallCommit {
            installation: PackageInstallationRecord {
                package_id: self.manifest.package_id.clone(),
                schema_version: self.manifest.schema_version,
            },
            profile: profile.clone(),
            lock: AgentPackageLock::from_installed_manifest(
                self.manifest.clone(),
                self.bindings.binding_hashes().clone(),
            ),
        });
        Ok(())
    }
}
