use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use serde::Serialize;

use crate::agent_package::{
    AgentPackageLock, AgentPackageManifest, AgentPackageValidator, PackageValidationIssue,
};
use crate::storage::{
    EventRecord, PendingStoreWrite, StorageError, StorageResult, TransactionName,
    TransactionOperation, TransactionRunner, UnitOfWork,
};
use crate::user_customization::{
    AgentProfile, AgentProfileId, AgentProfileReference, AgentSlotKind, AgentTemplate,
    InMemoryAgentProfileRepository,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallationRecord {
    pub package_id: String,
    pub schema_version: u32,
    pub host_binding_state: PackageHostBindingState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PackageHostBindingState {
    NeedsLLMBinding,
    HostUnbound,
    Ready,
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

    fn commit_install(&self, commit: PackageInstallCommit) {
        let mut inner = self
            .inner
            .lock()
            .expect("package install store mutex poisoned");
        inner.installations.push(commit.installation);
        inner.agent_profile_references.push(commit.profile);
        inner.package_locks.push(commit.lock);
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

    pub fn installation(&self, installation_id: &str) -> Option<PackageInstallationRecord> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .installations
            .iter()
            .find(|record| record.package_id == installation_id)
            .cloned()
    }

    pub fn installed_profile(
        &self,
        installation_id: &str,
    ) -> Option<InstalledAgentProfileReference> {
        self.inner
            .lock()
            .expect("package install store mutex poisoned")
            .agent_profile_references
            .iter()
            .find(|record| record.package_id == installation_id)
            .cloned()
    }

    pub fn transition_host_binding_state(
        &self,
        installation_id: &str,
        expected: PackageHostBindingState,
        next: PackageHostBindingState,
    ) -> StorageResult<PackageInstallationRecord> {
        let mut inner = self
            .inner
            .lock()
            .expect("package install store mutex poisoned");
        let installation = inner
            .installations
            .iter_mut()
            .find(|record| record.package_id == installation_id)
            .ok_or_else(|| {
                StorageError::new(
                    "package.installation_not_found",
                    "package installation was not found",
                )
            })?;
        if installation.host_binding_state != expected {
            return Err(StorageError::new(
                "package.host_binding_state_stale",
                "package host-binding state changed before transition",
            ));
        }
        installation.host_binding_state = next;
        Ok(installation.clone())
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

    fn commit(self: Box<Self>) {
        self.store.commit_install(self.commit);
    }
}

#[derive(Clone, Debug, Default)]
struct PackageInstallRecords {
    installations: Vec<PackageInstallationRecord>,
    agent_profile_references: Vec<InstalledAgentProfileReference>,
    package_locks: Vec<AgentPackageLock>,
    reject_commits: bool,
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
    profile_repository: InMemoryAgentProfileRepository,
}

impl AgentPackageInstaller {
    pub fn new(
        runner: Box<dyn TransactionRunner>,
        store: InMemoryPackageInstallStore,
        profile_repository: InMemoryAgentProfileRepository,
    ) -> Self {
        Self {
            runner,
            store,
            profile_repository,
        }
    }

    pub fn install(
        &self,
        manifest: AgentPackageManifest,
    ) -> StorageResult<InstalledAgentProfileReference> {
        let manifest = manifest.translated_for_install();
        let plan = PackageInstallPlan::from_manifest(&manifest);
        if !plan.validation_issues.is_empty() {
            return Err(StorageError::new(
                "package.validation_failed",
                "package manifest failed validation",
            ));
        }

        let mut operation = PackageInstallOperation {
            manifest,
            store: self.store.clone(),
            profile_repository: self.profile_repository.clone(),
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
        PackageInstallPlan::from_manifest(&manifest.translated_for_install()).into_preview()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PackageInstallPreview {
    pub package_id: String,
    pub validation_issues: Vec<PackageInstallPreviewIssue>,
    pub operations: Vec<PackageInstallPreviewOperation>,
    pub required_local_bindings: Vec<PackageInstallLocalBindingRequirement>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PackageInstallPreviewIssue {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PackageInstallPreviewOperation {
    pub code: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PackageInstallLocalBindingRequirement {
    pub key: String,
    pub purpose: String,
}

struct PackageInstallPlan {
    package_id: String,
    validation_issues: Vec<PackageInstallPreviewIssue>,
    operations: Vec<PackageInstallPreviewOperation>,
    required_local_bindings: Vec<PackageInstallLocalBindingRequirement>,
}

impl PackageInstallPlan {
    fn from_manifest(manifest: &AgentPackageManifest) -> Self {
        let validation = AgentPackageValidator.validate(manifest);
        let validation_issues = validation
            .issues
            .iter()
            .map(PackageInstallPreviewIssue::from_validation_issue)
            .collect::<Vec<_>>();

        if !validation_issues.is_empty() {
            return Self {
                package_id: manifest.package_id.clone(),
                validation_issues,
                operations: Vec::new(),
                required_local_bindings: Vec::new(),
            };
        }

        Self {
            package_id: manifest.package_id.clone(),
            validation_issues,
            operations: vec![
                PackageInstallPreviewOperation {
                    code: "package.install.record.create".to_string(),
                },
                PackageInstallPreviewOperation {
                    code: "package.install.profile.create".to_string(),
                },
                PackageInstallPreviewOperation {
                    code: "package.install.llm_slot.create".to_string(),
                },
                PackageInstallPreviewOperation {
                    code: "package.install.lock.create".to_string(),
                },
            ],
            required_local_bindings: Vec::new(),
        }
    }

    fn into_preview(self) -> PackageInstallPreview {
        PackageInstallPreview {
            package_id: self.package_id,
            validation_issues: self.validation_issues,
            operations: self.operations,
            required_local_bindings: self.required_local_bindings,
        }
    }
}

impl PackageInstallPreviewIssue {
    fn from_validation_issue(issue: &PackageValidationIssue) -> Self {
        Self {
            code: issue.code.clone(),
            message: issue.message.clone(),
        }
    }
}

struct PackageInstallOperation {
    manifest: AgentPackageManifest,
    store: InMemoryPackageInstallStore,
    profile_repository: InMemoryAgentProfileRepository,
    result: Option<PackageInstallCommit>,
}

struct InstalledProfilePlan {
    profile: AgentProfile,
}

impl TransactionOperation for PackageInstallOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let plan = installed_profile_from_manifest(&self.manifest)?;
        let profile = InstalledAgentProfileReference::new(
            plan.profile.reference(),
            self.manifest.package_id.clone(),
        );
        let commit = PackageInstallCommit {
            installation: PackageInstallationRecord {
                package_id: self.manifest.package_id.clone(),
                schema_version: self.manifest.schema_version,
                host_binding_state: PackageHostBindingState::NeedsLLMBinding,
            },
            profile: profile.clone(),
            lock: AgentPackageLock::from_installed_manifest(self.manifest.clone(), BTreeMap::new()),
        };
        tx.events().append(EventRecord::new(
            &self.manifest.package_id,
            "package.installed",
        ))?;
        self.profile_repository.stage(tx, plan.profile)?;
        self.store.stage(tx, commit.clone())?;
        self.result = Some(commit);
        Ok(())
    }
}

fn installed_profile_from_manifest(
    manifest: &AgentPackageManifest,
) -> StorageResult<InstalledProfilePlan> {
    let template = AgentTemplate::package_installed_v1();
    let llm_slot = manifest.llm_slot.clone().ok_or_else(|| {
        StorageError::new(
            "package.llm_slot.required",
            "installable agent packages must include a portable LLM slot",
        )
    })?;
    let model_slot_id = template
        .slot_id_for_kind(AgentSlotKind::Model)
        .ok_or_else(|| {
            StorageError::new(
                "package.install_model_slot_missing",
                "package-installed agent template does not expose a model slot",
            )
        })?
        .clone();
    if llm_slot.requirements().slot_id() != model_slot_id.as_str() {
        return Err(StorageError::new(
            "package.llm_slot.slot_mismatch",
            "package LLM slot must target the package template model slot",
        ));
    }
    let profile = AgentProfile::installed_package_host_slot_profile(
        AgentProfileId::new(format!("profile:{}", manifest.package_id)),
        &template,
        manifest.name.clone(),
        llm_slot,
    );

    Ok(InstalledProfilePlan { profile })
}
