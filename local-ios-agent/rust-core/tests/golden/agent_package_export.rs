use local_ios_agent_runtime::agent_package::{AgentPackageExporter, AgentPackageLock};

#[test]
fn agent_package_export_matches_golden_files() {
    let lock = AgentPackageLock::fixture_installed_profile();
    let exported = AgentPackageExporter.export(&lock).unwrap();

    assert_eq!(
        exported.files.get("agent.yaml").map(String::as_str),
        Some(include_str!(
            "../fixtures/golden/agent_package_export/agent.yaml"
        ))
    );
    assert_eq!(
        exported.files.get("model.yaml").map(String::as_str),
        Some(include_str!(
            "../fixtures/golden/agent_package_export/model.yaml"
        ))
    );
}
