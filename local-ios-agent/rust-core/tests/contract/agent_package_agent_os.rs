use local_ios_agent_runtime::agent_package::{
    AgentPackageExporter, AgentPackageInstaller, AgentPackageLock, AgentPackageManifest,
    AgentPackageReader, AgentPackageValidator, InMemoryPackageInstallStore,
    PackageHostBindingState, PackagePath,
};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::InMemoryAgentProfileRepository;

#[test]
fn v2_package_install_creates_only_a_host_bound_profile() {
    let store = InMemoryPackageInstallStore::default();
    let profiles = InMemoryAgentProfileRepository::default();
    let installer = AgentPackageInstaller::new(
        Box::new(InMemoryTransactionRunner::default()),
        store.clone(),
        profiles.clone(),
    );

    let installed = installer
        .install(AgentPackageManifest::fixture_valid())
        .unwrap();
    let profile = profiles.profile(installed.profile()).unwrap();

    assert!(profile.llm_slot().is_some());
    assert!(profile.readiness().has_issue("host_binding.missing"));
    assert_eq!(
        store.installation("agent.fixture").unwrap().host_binding_state,
        PackageHostBindingState::NeedsLLMBinding
    );
    assert_eq!(store.package_locks()[0].schema_version, 2);
}

#[test]
fn private_schema_v1_reader_returns_v2_portable_state() {
    let reader = AgentPackageReader::fixture_with_files([
        (
            "agent.yaml",
            include_str!("../fixtures/agent_package/valid/agent.yaml"),
        ),
        (
            "model.yaml",
            include_str!("../fixtures/agent_package/valid/model.yaml"),
        ),
    ]);

    let manifest = reader.read_manifest(&PackagePath::fixture()).unwrap();
    let persisted = serde_json::to_string(&manifest).unwrap();

    assert_eq!(manifest.schema_version, 2);
    assert_eq!(
        manifest.llm_slot.as_ref().unwrap().model_id_hint(),
        Some("gpt-fixture")
    );
    for forbidden in ["credential_ref", "local_path", "provider_id"] {
        assert!(!persisted.contains(forbidden));
    }
}

#[test]
fn exported_v2_package_round_trips_without_model_sidecar() {
    let lock = AgentPackageLock::from_installed_manifest(AgentPackageManifest::fixture_valid());
    let exported = AgentPackageExporter::default().export(&lock).unwrap();
    let manifest = AgentPackageReader::fixture_with_files(exported.files.clone())
        .read_manifest(&PackagePath::fixture())
        .unwrap();

    assert_eq!(exported.files.len(), 1);
    assert!(exported.files.contains_key("agent.yaml"));
    assert_eq!(manifest, AgentPackageManifest::fixture_valid());
}

#[test]
fn package_reader_rejects_path_traversal() {
    let reader = AgentPackageReader::fixture_with_file("prompts/../secrets.txt", "secret");

    let error = reader.inspect(&PackagePath::fixture()).unwrap_err();

    assert_eq!(error.code(), "package.path_traversal");
}

#[test]
fn validator_requires_schema_v2_and_portable_llm_slot() {
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.schema_version = 1;
    manifest.llm_slot = None;

    let report = AgentPackageValidator::default().validate(&manifest);

    assert!(report.has_issue("package.schema_version.invalid"));
    assert!(report.has_issue("package.llm_slot.required"));
}

#[test]
fn failed_validation_leaves_no_install_side_effects() {
    let store = InMemoryPackageInstallStore::default();
    let profiles = InMemoryAgentProfileRepository::default();
    let installer = AgentPackageInstaller::new(
        Box::new(InMemoryTransactionRunner::default()),
        store.clone(),
        profiles,
    );
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.name = "sk-secret-value".into();

    let error = installer.install(manifest).unwrap_err();

    assert_eq!(error.code(), "package.validation_failed");
    assert!(store.installations().is_empty());
    assert!(store.package_locks().is_empty());
}
