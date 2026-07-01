use crate::support::agent_os_fixtures::AgentOsTestWorld;
use crate::support::assertions::assert_redacted_debug_output;

use local_ios_agent_runtime::agent_package::AgentPackageManifest;

#[test]
fn package_install_preview_matches_golden_and_mentions_all_transaction_writes() {
    let world = AgentOsTestWorld::new();
    let preview = world
        .package_installer()
        .preview(&AgentPackageManifest::fixture_valid());
    let actual = serde_json::to_string_pretty(&preview).unwrap() + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/package_install_preview.json")
    );
}

#[test]
fn installed_profile_debug_summary_matches_golden_and_is_redacted() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world
        .profile_repository
        .profile(installed.profile())
        .unwrap();
    let actual = serde_json::to_string_pretty(&profile.debug_summary()).unwrap() + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/profile_summary.json")
    );
}
