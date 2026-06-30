use local_ios_agent_runtime::agent_package::{
    AgentPackageExporter, AgentPackageInstaller, AgentPackageLock, AgentPackageManifest,
    AgentPackageReader, AgentPackageValidator, AgentProfileUpgradePlanner, ComponentVersionStatus,
    InMemoryPackageInstallStore, LocalBindings, PackagePath, RuntimeComponentCatalog,
};
use local_ios_agent_runtime::storage::{
    InMemoryTransactionRunner, StorageError, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner,
};

#[test]
fn package_reader_rejects_path_traversal() {
    let reader = AgentPackageReader::fixture_with_file("prompts/../secrets.txt", "secret");

    let error = reader.inspect(&PackagePath::fixture()).unwrap_err();

    assert_eq!(error.code(), "package.path_traversal");
}

#[test]
fn package_reader_reads_valid_agent_manifest_fixture() {
    let reader = AgentPackageReader::fixture_with_files([
        (
            "agent.yaml",
            include_str!("fixtures/agent_package/valid/agent.yaml"),
        ),
        (
            "model.yaml",
            include_str!("fixtures/agent_package/valid/model.yaml"),
        ),
    ]);

    let manifest = reader.read_manifest(&PackagePath::fixture()).unwrap();

    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.package_id, "agent.fixture");
    assert_eq!(manifest.model.unwrap().model_id, "gpt-fixture");
}

#[test]
fn manifest_rejects_credential_ref_and_local_path() {
    let manifest = AgentPackageManifest::fixture_with_credential_ref_and_local_path();
    let report = AgentPackageValidator::default().validate(&manifest);

    assert!(report.has_issue("package.credential_ref.forbidden"));
    assert!(report.has_issue("package.local_path.forbidden"));
}

#[test]
fn package_export_does_not_include_local_lock() {
    let profile = AgentPackageLock::fixture_installed_profile();
    let exported = AgentPackageExporter::default().export(&profile).unwrap();

    assert!(!exported.files.contains_key("agent.lock"));
    assert!(!exported.serialized_text().contains("CredentialRef"));
}

struct FailingInstallRunner;

impl TransactionRunner for FailingInstallRunner {
    fn run(
        &self,
        _name: TransactionName,
        _operation: &mut dyn TransactionOperation,
    ) -> StorageResult<()> {
        Err(StorageError::forced("install failed"))
    }
}

#[test]
fn package_install_rolls_back_local_records_when_transaction_fails() {
    let store = InMemoryPackageInstallStore::default();
    let installer = AgentPackageInstaller::new(Box::new(FailingInstallRunner), store.clone());

    let error = installer
        .install(
            AgentPackageManifest::fixture_valid(),
            LocalBindings::empty(),
        )
        .unwrap_err();

    assert_eq!(error.code(), "storage.forced");
    assert!(store.installations().is_empty());
    assert!(store.agent_profiles().is_empty());
    assert!(store.package_locks().is_empty());
}

#[test]
fn installer_preview_reports_records_without_writing_store() {
    let store = InMemoryPackageInstallStore::default();
    let installer = AgentPackageInstaller::new(
        Box::new(InMemoryTransactionRunner::default()),
        store.clone(),
    );

    let preview = installer.preview(&AgentPackageManifest::fixture_valid());

    assert_eq!(preview.package_id, "agent.fixture");
    assert!(preview
        .operations
        .iter()
        .any(|operation| operation.code == "package.install.profile.create"));
    assert!(store.installations().is_empty());
    assert!(store.agent_profiles().is_empty());
    assert!(store.package_locks().is_empty());
}

#[test]
fn upgrade_planner_reports_component_version_status() {
    let lock = AgentPackageLock::fixture_with_component("prompt.identity", "1.0.0");
    let runtime_catalog =
        RuntimeComponentCatalog::fixture_with_component("prompt.identity", "1.1.0");
    let report = AgentProfileUpgradePlanner::default()
        .diff_against_runtime_catalog(&lock, &runtime_catalog)
        .unwrap();

    assert_eq!(
        report.status_for("prompt.identity"),
        Some(ComponentVersionStatus::UpdateAvailable)
    );
    assert!(report
        .operations
        .iter()
        .any(|operation| operation.code == "component.update.available"));
}

#[test]
fn upgrade_planner_marks_missing_runtime_component_incompatible() {
    let lock = AgentPackageLock::fixture_with_component("tool.calendar", "2.0.0");
    let runtime_catalog = RuntimeComponentCatalog::empty();
    let report = AgentProfileUpgradePlanner::default()
        .diff_against_runtime_catalog(&lock, &runtime_catalog)
        .unwrap();

    assert_eq!(
        report.status_for("tool.calendar"),
        Some(ComponentVersionStatus::Unavailable)
    );
    assert!(report.has_blocking_issue("component.runtime.unavailable"));
}
