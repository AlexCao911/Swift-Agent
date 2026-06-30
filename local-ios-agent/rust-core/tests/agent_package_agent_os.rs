use local_ios_agent_runtime::agent_package::{
    AgentPackageExporter, AgentPackageInstaller, AgentPackageLock, AgentPackageManifest,
    AgentPackageReader, AgentPackageValidator, AgentProfileUpgradePlanner, ComponentVersionStatus,
    InMemoryPackageInstallStore, LocalBindings, PackagePath, RuntimeComponentCatalog,
};
use local_ios_agent_runtime::storage::{
    InMemoryTransactionRunner, StorageError, StorageResult, TransactionName, TransactionOperation,
    TransactionRunner,
};
use std::collections::BTreeMap;
use tempfile::TempDir;

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
fn exported_package_round_trips_through_reader() {
    let profile = AgentPackageLock::fixture_installed_profile();
    let exported = AgentPackageExporter::default().export(&profile).unwrap();

    let manifest = AgentPackageReader::fixture_with_files(exported.files.clone())
        .read_manifest(&PackagePath::fixture())
        .unwrap();

    assert!(exported.files.contains_key("agent.yaml"));
    assert!(exported.files.contains_key("model.yaml"));
    assert_eq!(manifest.package_id, profile.manifest().package_id);
    assert_eq!(manifest.model.unwrap().model_id, "gpt-fixture");
}

#[test]
fn exporter_rejects_lock_with_non_portable_model_file() {
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.model_file = Some("../secret-model.yaml".to_string());
    let lock = AgentPackageLock::from_installed_manifest(manifest, BTreeMap::new());

    let error = AgentPackageExporter::default().export(&lock).unwrap_err();

    assert_eq!(error.code(), "package.path_traversal");
}

#[cfg(unix)]
#[test]
fn package_reader_rejects_symlink_escape_from_real_directory() {
    let package_dir = TempDir::new().unwrap();
    let outside_dir = TempDir::new().unwrap();
    std::fs::write(outside_dir.path().join("secret.txt"), "secret").unwrap();
    std::fs::create_dir(package_dir.path().join("prompts")).unwrap();
    std::os::unix::fs::symlink(
        outside_dir.path().join("secret.txt"),
        package_dir.path().join("prompts/leak.txt"),
    )
    .unwrap();

    let reader = AgentPackageReader::from_directory(package_dir.path()).unwrap();
    let error = reader.inspect(&PackagePath::fixture()).unwrap_err();

    assert_eq!(error.code(), "package.symlink_escape");
}

#[test]
fn manifest_rejects_credential_ref_and_local_path() {
    let manifest = AgentPackageManifest::fixture_with_credential_ref_and_local_path();
    let report = AgentPackageValidator::default().validate(&manifest);

    assert!(report.has_issue("package.credential_ref.forbidden"));
    assert!(report.has_issue("package.local_path.forbidden"));
}

#[test]
fn manifest_rejects_unknown_fields_secret_like_values_and_bad_hash_metadata() {
    let reader = AgentPackageReader::fixture_with_files([
        (
            "agent.yaml",
            "schema_version: 1\npackage_id: agent.fixture\nname: sk-secret-value\nmodel_file: model.yaml\nsurprise: true\npackage_hash: md5:abc\nsignature: sig-fixture\n",
        ),
        (
            "model.yaml",
            "provider_id: provider.openai_compatible\nmodel_id: gpt-fixture\nunknown_model_key: ignored\n",
        ),
    ]);

    let manifest = reader.read_manifest(&PackagePath::fixture()).unwrap();
    let report = AgentPackageValidator::default().validate(&manifest);

    assert!(report.has_issue("package.unknown_field.forbidden"));
    assert!(report.has_issue("package.secret_value.forbidden"));
    assert!(report.has_issue("package.hash.invalid"));
}

#[test]
fn manifest_rejects_non_portable_model_file_and_missing_model() {
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.model_file = Some("../model.yaml".to_string());
    manifest.model = None;

    let report = AgentPackageValidator::default().validate(&manifest);

    assert!(report.has_issue("package.model_file.path_invalid"));
    assert!(report.has_issue("package.model_file.model_missing"));
}

#[test]
fn signed_manifest_is_rejected_until_signature_verifier_exists() {
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.signature = Some("sig-fixture".to_string());

    let report = AgentPackageValidator::default().validate(&manifest);

    assert!(report.has_issue("package.signature.unsupported"));
}

#[test]
fn package_export_does_not_include_local_lock() {
    let profile = AgentPackageLock::fixture_installed_profile();
    let exported = AgentPackageExporter::default().export(&profile).unwrap();

    assert!(!exported.files.contains_key("agent.lock"));
    assert!(!exported.serialized_text().contains("CredentialRef"));
}

#[test]
fn package_install_rejects_invalid_manifest_before_writing_lock() {
    let store = InMemoryPackageInstallStore::default();
    let installer = AgentPackageInstaller::new(
        Box::new(InMemoryTransactionRunner::default()),
        store.clone(),
    );

    let error = installer
        .install(
            AgentPackageManifest::fixture_with_credential_ref_and_local_path(),
            LocalBindings::empty(),
        )
        .unwrap_err();

    assert_eq!(error.code(), "package.validation_failed");
    assert!(store.installations().is_empty());
    assert!(store.agent_profiles().is_empty());
    assert!(store.package_locks().is_empty());
}

#[test]
fn package_install_rejects_signed_manifest_before_transaction() {
    let store = InMemoryPackageInstallStore::default();
    let installer = AgentPackageInstaller::new(
        Box::new(InMemoryTransactionRunner::default()),
        store.clone(),
    );
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.signature = Some("sig-fixture".to_string());

    let error = installer
        .install(manifest, LocalBindings::empty())
        .unwrap_err();

    assert_eq!(error.code(), "package.validation_failed");
    assert!(store.installations().is_empty());
    assert!(store.agent_profiles().is_empty());
    assert!(store.package_locks().is_empty());
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
fn package_install_commits_records_and_event_in_single_transaction() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let store = InMemoryPackageInstallStore::default();
    let installer = AgentPackageInstaller::new(Box::new(runner), store.clone());

    installer
        .install(
            AgentPackageManifest::fixture_valid(),
            LocalBindings::empty(),
        )
        .unwrap();

    assert_eq!(store.installations().len(), 1);
    assert_eq!(store.agent_profiles().len(), 1);
    assert_eq!(store.package_locks().len(), 1);
    let events = event_store.stream("agent.fixture").unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type(), "package.installed");
}

#[test]
fn package_install_store_validation_failure_rolls_back_package_event() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let store = InMemoryPackageInstallStore::fixture_rejecting_commits();
    let installer = AgentPackageInstaller::new(Box::new(runner), store.clone());

    let error = installer
        .install(
            AgentPackageManifest::fixture_valid(),
            LocalBindings::empty(),
        )
        .unwrap_err();

    assert_eq!(error.code(), "package.install_store.rejected");
    assert!(store.installations().is_empty());
    assert!(store.agent_profiles().is_empty());
    assert!(store.package_locks().is_empty());
    assert!(event_store.stream("agent.fixture").unwrap().is_empty());
}

#[test]
fn package_install_store_apply_failure_rolls_back_package_event() {
    let runner = InMemoryTransactionRunner::default();
    let event_store = runner.event_store();
    let store = InMemoryPackageInstallStore::fixture_failing_apply();
    let installer = AgentPackageInstaller::new(Box::new(runner), store.clone());

    let error = installer
        .install(
            AgentPackageManifest::fixture_valid(),
            LocalBindings::empty(),
        )
        .unwrap_err();

    assert_eq!(error.code(), "package.install_store.apply_failed");
    assert!(store.installations().is_empty());
    assert!(store.agent_profiles().is_empty());
    assert!(store.package_locks().is_empty());
    assert!(event_store.stream("agent.fixture").unwrap().is_empty());
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
