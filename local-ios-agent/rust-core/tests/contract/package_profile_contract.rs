use crate::support::agent_os_fixtures::AgentOsTestWorld;

use local_ios_agent_runtime::agent_package::{AgentPackageManifest, LocalBindings};
use local_ios_agent_runtime::model::ModelBindingId;
use local_ios_agent_runtime::user_customization::{AgentProfileId, AgentProfileReference};

#[test]
fn package_install_creates_profile_that_is_version_pinned_and_repository_resolvable() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();

    let profile_ref = installed.profile();
    assert!(
        profile_ref.profile_version().is_some(),
        "installed profile must be version-pinned"
    );

    let profile = world
        .profile_repository
        .profile(profile_ref)
        .expect("installed package must create a real profile");

    assert_eq!(profile.id(), profile_ref.profile_id());
    assert_eq!(Some(profile.version()), profile_ref.profile_version());
    assert!(
        profile.model_binding().is_some(),
        "fixture package must install a model binding"
    );
}

#[test]
fn package_installed_model_binding_is_catalog_resolvable_and_has_local_credential_binding() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();
    let model_binding = profile.model_binding().expect("model binding exists");

    assert!(
        world
            .model_catalog
            .contains_exact_selection(model_binding.selection()),
        "installed package must register the model selection it puts in the profile"
    );

    assert_eq!(
        profile
            .local_bindings()
            .credential_ref(model_binding.selection().provider_account_id()),
        Some("credential.openai.default"),
        "model provider account must resolve to installed local credential binding"
    );
}

#[test]
fn package_install_rejects_manifest_that_would_create_non_pinnable_profile() {
    let world = AgentOsTestWorld::new();
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.model.as_mut().unwrap().model_id.clear();

    let error = world
        .package_installer()
        .install(
            manifest,
            LocalBindings::empty().with_credential_ref(
                "model.account",
                "credential.openai.default",
                "sha256:local-binding",
            ),
        )
        .expect_err("blank model id must fail before profile persistence");

    assert_eq!(error.code(), "package.validation_failed");
    assert!(
        world.package_store.installations().is_empty(),
        "invalid package install must not write installation records"
    );
}

#[test]
fn package_install_rejects_secret_like_manifest_and_leaves_no_install_side_effects() {
    let world = AgentOsTestWorld::new();
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.name = "sk-live-secret-value".to_string();

    let error = world
        .package_installer()
        .install(
            manifest,
            LocalBindings::empty().with_credential_ref(
                "model.account",
                "credential.openai.default",
                "sha256:local-binding",
            ),
        )
        .expect_err("secret-like package values must fail before persistence");

    assert_eq!(error.code(), "package.validation_failed");
    assert!(
        world.package_store.installations().is_empty(),
        "secret-like package install must not write installation records"
    );
    assert!(
        world
            .profile_repository
            .profile(&AgentProfileReference::latest(AgentProfileId::new(
                "profile:agent.fixture"
            )))
            .is_none(),
        "secret-like package install must not persist an installed profile"
    );
    assert!(
        world
            .model_catalog
            .selection(&ModelBindingId::new("model_binding:agent.fixture:primary"))
            .is_none(),
        "secret-like package install must not persist model binding selection"
    );
}
