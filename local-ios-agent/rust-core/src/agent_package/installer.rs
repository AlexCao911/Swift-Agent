use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::agent_package::{AgentPackageLock, AgentPackageManifest, AgentPackageValidator};
use crate::storage::{
    EventRecord, PendingStoreWrite, StorageError, StorageResult, TransactionName,
    TransactionOperation, TransactionRunner, UnitOfWork,
};
use crate::user_customization::{AgentProfileId, AgentProfileReference};

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
pub struct InstalledAgentProfileReference {
    profile: AgentProfileReference,
    package_id: String,
}

impl InstalledAgentProfileReference {
    pub fn new(profile: AgentProfileReference, package_id: impl Into<String>) -> Self {
        Self {
            profile,
            package_id: package_id.into(),
        }
    }

    pub fn profile(&self) -> &AgentProfileReference {
        &self.profile
    }

    pub fn package_id(&self) -> &str {
        &self.package_id
    }
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryPackageInstallStore {
    inner: Arc<Mutex<PackageInstallRecords>>,
}

impl InMemoryPackageInstallStore {
    pub fn fixture_rejecting_commits() -> Self {
        Self {
            inner: Arc::new(Mutex::new(PackageInstallRecords {
                reject_commits: true,
                ..PackageInstallRecords::default()
            })),
        }
    }

    pub fn fixture_failing_apply() -> Self {
        Self {
            inner: Arc::new(Mutex::new(PackageInstallRecords {
                fail_apply: true,
                ..PackageInstallRecords::default()
            })),
        }
    }

    pub fn stage(&self, tx: &mut UnitOfWork, commit: PackageInstallCommit) -> StorageResult<()> {
        tx.push_store_write(Box::new(PendingPackageInstallWrite {
            store: self.clone(),
            commit,
        }));
        Ok(())
    }

    fn validate_commit(&self, commit: &PackageInstallCommit) -> StorageResult<()> {
        let inner = self
            .inner
            .lock()
            .expect("package install store mutex poisoned");
        if inner.reject_commits {
            return Err(StorageError::new(
                "package.install_store.rejected",
                "package install store rejected commit",
            ));
        }
        if inner
            .installations
            .iter()
            .any(|record| record.package_id == commit.installation.package_id)
        {
            return Err(StorageError::new(
                "package.install.duplicate",
                "package installation already exists",
            ));
        }
        Ok(())
    }

    fn apply_commit(&self, commit: PackageInstallCommit) -> StorageResult<()> {
        let mut inner = self
            .inner
            .lock()
            .expect("package install store mutex poisoned");
        if inner.fail_apply {
            return Err(StorageError::new(
                "package.install_store.apply_failed",
                "package install store failed while applying commit",
            ));
        }
        inner.installations.push(commit.installation);
        inner.agent_profile_references.push(commit.profile);
        inner.package_locks.push(commit.lock);
        Ok(())
    }

    pub fn installations(&self) -> Vec<PackageInstallationRecord> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .installations
            .clone()
    }

    pub fn agent_profile_references(&self) -> Vec<InstalledAgentProfileReference> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .agent_profile_references
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

struct PendingPackageInstallWrite {
    store: InMemoryPackageInstallStore,
    commit: PackageInstallCommit,
}

impl PendingStoreWrite for PendingPackageInstallWrite {
    fn validate(&self) -> StorageResult<()> {
        self.store.validate_commit(&self.commit)
    }

    fn apply(self: Box<Self>) -> StorageResult<()> {
        self.store.apply_commit(self.commit)
    }
}

#[derive(Clone, Debug, Default)]
struct PackageInstallRecords {
    installations: Vec<PackageInstallationRecord>,
    agent_profile_references: Vec<InstalledAgentProfileReference>,
    package_locks: Vec<AgentPackageLock>,
    reject_commits: bool,
    fail_apply: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallCommit {
    installation: PackageInstallationRecord,
    profile: InstalledAgentProfileReference,
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
    ) -> StorageResult<InstalledAgentProfileReference> {
        let validation = AgentPackageValidator::default().validate(&manifest);
        if !validation.is_valid() {
            return Err(StorageError::new(
                "package.validation_failed",
                "package manifest failed validation",
            ));
        }

        let mut operation = PackageInstallOperation {
            manifest,
            bindings,
            store: self.store.clone(),
            result: None,
        };

        self.runner.run(
            TransactionName::new("agent_package.install"),
            &mut operation,
        )?;

        let commit = operation
            .result
            .expect("package install operation must set typed result on success");
        Ok(commit.profile)
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
    store: InMemoryPackageInstallStore,
    result: Option<PackageInstallCommit>,
}

impl TransactionOperation for PackageInstallOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let profile = InstalledAgentProfileReference::new(
            AgentProfileReference::new(AgentProfileId::new(format!(
                "profile:{}",
                self.manifest.package_id
            ))),
            self.manifest.package_id.clone(),
        );
        let commit = PackageInstallCommit {
            installation: PackageInstallationRecord {
                package_id: self.manifest.package_id.clone(),
                schema_version: self.manifest.schema_version,
            },
            profile: profile.clone(),
            lock: AgentPackageLock::from_installed_manifest(
                self.manifest.clone(),
                self.bindings.binding_hashes().clone(),
            ),
        };
        tx.events().append(EventRecord::new(
            &self.manifest.package_id,
            "package.installed",
        ))?;
        self.store.stage(tx, commit.clone())?;
        self.result = Some(commit);
        Ok(())
    }
}
