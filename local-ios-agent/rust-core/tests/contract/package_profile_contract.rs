use crate::support::agent_os_fixtures::AgentOsTestWorld;

use local_ios_agent_runtime::agent_package::AgentPackageManifest;
use local_ios_agent_runtime::llm_contracts::{AgentLLMRequirements, LLMSlotV2, LLMToolCallingMode};
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
    assert!(profile.model_binding().is_none());
    assert!(
        profile.llm_slot().is_some(),
        "fixture package must install a V2 LLM slot"
    );
}

#[test]
fn package_installed_slot_has_no_concrete_catalog_or_credential_binding() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();
    assert!(profile.llm_slot().is_some());
    assert!(profile.model_binding().is_none());
    assert!(profile.local_bindings().is_empty());
    assert!(world
        .model_catalog
        .selection(&ModelBindingId::new("model_binding:agent.fixture:primary"))
        .is_none());
}

#[test]
fn package_install_rejects_llm_slot_that_does_not_match_template() {
    let world = AgentOsTestWorld::new();
    let mut manifest = AgentPackageManifest::fixture_valid().translated_for_install();
    manifest.llm_slot = Some(LLMSlotV2::new(AgentLLMRequirements::new(
        "slot.model.wrong",
        8_192,
        true,
        LLMToolCallingMode::Required,
    )));

    let error = world
        .package_installer()
        .install(manifest)
        .expect_err("mismatched portable slot must fail before profile persistence");

    assert_eq!(error.code(), "package.llm_slot.slot_mismatch");
    assert!(
        world.package_store.installations().is_empty(),
        "mismatched package install must not write installation records"
    );
}

#[test]
fn package_install_rejects_secret_like_manifest_and_leaves_no_install_side_effects() {
    let world = AgentOsTestWorld::new();
    let mut manifest = AgentPackageManifest::fixture_valid();
    manifest.name = "sk-live-secret-value".to_string();

    let error = world
        .package_installer()
        .install(manifest)
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
