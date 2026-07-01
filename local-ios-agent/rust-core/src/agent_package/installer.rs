use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use crate::agent_package::{AgentPackageLock, AgentPackageManifest, AgentPackageValidator};
use crate::model::{
    InMemoryModelBindingCatalog, ModelBindingId, ModelCatalogVersion, ModelSelection,
};
use crate::storage::{
    EventRecord, PendingStoreWrite, StorageError, StorageResult, TransactionName,
    TransactionOperation, TransactionRunner, UnitOfWork,
};
use crate::user_customization::{
    AgentProfile, AgentProfileId, AgentProfileLocalBindings, AgentProfileModelBinding,
    AgentProfileReference, AgentSlotKind, AgentTemplate, InMemoryAgentProfileRepository,
};

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LocalBindings {
    binding_hashes: BTreeMap<String, String>,
    credential_refs: BTreeMap<String, String>,
}

impl LocalBindings {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn binding_hashes(&self) -> &BTreeMap<String, String> {
        &self.binding_hashes
    }

    pub fn with_credential_ref(
        mut self,
        binding_key: impl Into<String>,
        credential_ref: impl Into<String>,
        binding_hash: impl Into<String>,
    ) -> Self {
        let binding_key = binding_key.into();
        self.credential_refs
            .insert(binding_key.clone(), credential_ref.into());
        self.binding_hashes.insert(binding_key, binding_hash.into());
        self
    }

    pub fn credential_ref(&self, binding_key: &str) -> Option<&str> {
        self.credential_refs.get(binding_key).map(String::as_str)
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
    model_catalog: InMemoryModelBindingCatalog,
}

impl AgentPackageInstaller {
    pub fn new(
        runner: Box<dyn TransactionRunner>,
        store: InMemoryPackageInstallStore,
        profile_repository: InMemoryAgentProfileRepository,
        model_catalog: InMemoryModelBindingCatalog,
    ) -> Self {
        Self {
            runner,
            store,
            profile_repository,
            model_catalog,
        }
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
            profile_repository: self.profile_repository.clone(),
            model_catalog: self.model_catalog.clone(),
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
                    code: "package.install.model_binding.create".to_string(),
                },
                PackageInstallPreviewOperation {
                    code: "package.install.lock.create".to_string(),
                },
            ],
            required_local_bindings: vec![PackageInstallLocalBindingRequirement {
                key: "model.account".to_string(),
                purpose: "remote_provider_account".to_string(),
            }],
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallPreview {
    pub package_id: String,
    pub operations: Vec<PackageInstallPreviewOperation>,
    pub required_local_bindings: Vec<PackageInstallLocalBindingRequirement>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallPreviewOperation {
    pub code: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PackageInstallLocalBindingRequirement {
    pub key: String,
    pub purpose: String,
}

struct PackageInstallOperation {
    manifest: AgentPackageManifest,
    bindings: LocalBindings,
    store: InMemoryPackageInstallStore,
    profile_repository: InMemoryAgentProfileRepository,
    model_catalog: InMemoryModelBindingCatalog,
    result: Option<PackageInstallCommit>,
}

struct InstalledProfilePlan {
    profile: AgentProfile,
    model_selection: ModelSelection,
}

impl TransactionOperation for PackageInstallOperation {
    fn execute(&mut self, tx: &mut UnitOfWork) -> StorageResult<()> {
        let plan = installed_profile_from_manifest(&self.manifest, &self.bindings)?;
        let profile = InstalledAgentProfileReference::new(
            plan.profile.reference(),
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
        self.model_catalog.stage(tx, plan.model_selection)?;
        self.profile_repository.stage(tx, plan.profile)?;
        self.store.stage(tx, commit.clone())?;
        self.result = Some(commit);
        Ok(())
    }
}

fn installed_profile_from_manifest(
    manifest: &AgentPackageManifest,
    bindings: &LocalBindings,
) -> StorageResult<InstalledProfilePlan> {
    const MODEL_ACCOUNT_BINDING_KEY: &str = "model.account";

    let template = AgentTemplate::package_installed_v1();
    let model = manifest.model.as_ref().ok_or_else(|| {
        StorageError::new(
            "package.model.required",
            "installable agent packages must include a model manifest",
        )
    })?;
    let credential_ref = bindings
        .credential_ref(MODEL_ACCOUNT_BINDING_KEY)
        .ok_or_else(|| {
            StorageError::new(
                "package.local_binding.model_account_required",
                "installing a package model requires a local model account binding",
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
    let provider_account_id = format!(
        "package.provider_account:{}:{}",
        manifest.package_id, MODEL_ACCOUNT_BINDING_KEY
    );
    let model_selection = ModelSelection::new(
        ModelBindingId::new(format!("model_binding:{}:primary", manifest.package_id)),
        provider_account_id.clone(),
        model.provider_id.clone(),
        model.model_id.clone(),
        ModelCatalogVersion::new(manifest.schema_version as u64),
    );
    let local_bindings = AgentProfileLocalBindings::default()
        .with_credential_ref(provider_account_id, credential_ref.to_string());
    let profile = AgentProfile::installed_package_profile(
        AgentProfileId::new(format!("profile:{}", manifest.package_id)),
        &template,
        manifest.name.clone(),
        Some(AgentProfileModelBinding::new(
            model_slot_id,
            model_selection.clone(),
        )),
        local_bindings,
    );

    Ok(InstalledProfilePlan {
        profile,
        model_selection,
    })
}
