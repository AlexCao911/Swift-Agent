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

#[test]
fn taxonomy_harnesses_include_every_rust_file_in_their_directory() {
    let tests_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let taxonomy_dirs = ["unit", "contract", "integration", "golden", "lint"];

    let mut violations = Vec::new();
    for taxonomy in taxonomy_dirs {
        for missing in missing_harness_modules(&tests_root, taxonomy) {
            violations.push(format!(
                "tests/{taxonomy}/{missing} is not included by tests/{taxonomy}.rs"
            ));
        }
    }

    assert!(
        violations.is_empty(),
        "test harness coverage violations:\n{}",
        violations.join("\n")
    );
}

#[test]
fn harness_coverage_detects_unmounted_taxonomy_file() {
    let temp = tempfile::tempdir().unwrap();
    let tests_root = temp.path();
    fs::create_dir_all(tests_root.join("contract")).unwrap();
    fs::write(
        tests_root.join("contract.rs"),
        r#"
#[path = "contract/mounted.rs"]
mod mounted;
"#,
    )
    .unwrap();
    fs::write(tests_root.join("contract/mounted.rs"), "").unwrap();
    fs::write(tests_root.join("contract/unmounted.rs"), "").unwrap();

    assert_eq!(
        missing_harness_modules(tests_root, "contract"),
        vec!["unmounted.rs".to_string()]
    );
}

fn missing_harness_modules(tests_root: &Path, taxonomy: &str) -> Vec<String> {
    let taxonomy_dir = tests_root.join(taxonomy);
    let harness_path = tests_root.join(format!("{taxonomy}.rs"));
    let harness_source = fs::read_to_string(&harness_path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", harness_path.display()));

    let mut missing = Vec::new();
    for entry in fs::read_dir(&taxonomy_dir)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", taxonomy_dir.display()))
    {
        let entry = entry.expect("taxonomy entry is readable");
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }

        let file_name = entry.file_name().to_string_lossy().to_string();
        let module_name = path
            .file_stem()
            .and_then(|stem| stem.to_str())
            .expect("rust test file has utf-8 stem");
        let expected_path = format!("{taxonomy}/{file_name}");
        if !harness_source_declares_module(&harness_source, &expected_path, module_name) {
            missing.push(file_name);
        }
    }

    missing.sort();
    missing
}

fn harness_source_declares_module(source: &str, expected_path: &str, module_name: &str) -> bool {
    let expected_path_attr = format!(r#"#[path = "{expected_path}"]"#);
    let expected_module = format!("mod {module_name};");
    source.contains(&expected_path_attr) && source.contains(&expected_module)
}
