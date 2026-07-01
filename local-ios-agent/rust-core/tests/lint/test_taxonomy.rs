use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

#[test]
fn rust_integration_tests_are_grouped_by_taxonomy() {
    let tests_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let allowed_root_files = BTreeSet::from([
        "unit.rs",
        "contract.rs",
        "integration.rs",
        "golden.rs",
        "lint.rs",
    ]);
    let allowed_root_dirs = BTreeSet::from([
        "unit",
        "contract",
        "integration",
        "golden",
        "lint",
        "support",
        "fixtures",
    ]);

    let mut violations = Vec::new();
    for entry in fs::read_dir(&tests_root).expect("tests directory exists") {
        let entry = entry.expect("test entry is readable");
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();

        if path.is_file() && path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            if !allowed_root_files.contains(name.as_str()) {
                violations.push(format!("root test file must move into taxonomy: {name}"));
            }
            continue;
        }

        if path.is_dir() && !allowed_root_dirs.contains(name.as_str()) {
            violations.push(format!(
                "root test directory is not a taxonomy directory: {name}"
            ));
        }
    }

    assert!(
        violations.is_empty(),
        "test taxonomy violations:\n{}",
        violations.join("\n")
    );
}
