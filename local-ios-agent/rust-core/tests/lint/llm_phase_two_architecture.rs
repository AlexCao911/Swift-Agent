use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
};

fn repository_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust-core must live below the repository root")
        .to_path_buf()
}

fn source_files(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    fn visit(path: &Path, extensions: &[&str], output: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(path) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if matches!(
                    path.file_name().and_then(|name| name.to_str()),
                    Some("target" | ".build" | "Artifacts" | "third_party" | "vendor")
                ) {
                    continue;
                }
                visit(&path, extensions, output);
            } else if path
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extensions.contains(&extension))
            {
                output.push(path);
            }
        }
    }

    let mut output = Vec::new();
    visit(root, extensions, &mut output);
    output.sort();
    output
}

#[test]
fn rust_agent_core_does_not_gain_swift_owned_concrete_model_details() {
    let root = repository_root();
    let rust_root = root.join("rust-core/src");
    let legacy_prefixes = [
        rust_root.join("core/local_llm.rs"),
        rust_root.join("core/desktop_minicpm.rs"),
        rust_root.join("inference"),
    ];
    let forbidden = [
        "OfficialModelCatalog",
        "LocalModelManifest",
        "LocalModelInstallation",
        "artifactSHA256",
        "downloadURL",
        "modelPath",
        "engineID",
        "CppInference",
    ];
    let mut findings = Vec::new();
    for path in source_files(&rust_root, &["rs"]) {
        if legacy_prefixes.iter().any(|prefix| path.starts_with(prefix)) {
            continue;
        }
        let source = fs::read_to_string(&path).expect("Rust source must be readable");
        for symbol in forbidden {
            if source.contains(symbol) {
                findings.push(format!("{}: {symbol}", path.display()));
            }
        }
    }
    assert!(
        findings.is_empty(),
        "Rust Agent code must not own catalog, download, path, engine, or C++ adapter details:\n{}",
        findings.join("\n")
    );

    let resolver = fs::read_to_string(rust_root.join("run_snapshot/resolver.rs")).unwrap();
    let preparation = fs::read_to_string(rust_root.join("run_snapshot/snapshot_service.rs")).unwrap();
    // The legacy resolver remains non-runnable for a V2 route until the Phase 4
    // production switch. The authoritative preparation path now commits V2
    // through the provider-neutral unified host runtime instead of this guard.
    assert!(resolver.contains("execution.host_slot_v2_not_runnable"));
    assert!(!preparation.contains("execution.host_slot_v2_not_runnable"));
    assert!(preparation.contains("pub fn with_host_runtime"));
    assert!(preparation.contains("commit_prepared_host_run(PreparedHostRunCommit"));
}

#[test]
fn swift_native_path_target_and_epoch_ownership_are_single_source() {
    let root = repository_root();
    let swift_sources = root.join("toolkit/Sources");
    let native_imports = source_files(&swift_sources, &["swift"])
        .into_iter()
        .filter(|path| {
            fs::read_to_string(path)
                .unwrap()
                .lines()
                .any(|line| line.trim() == "import LocalAgentInferenceNative")
        })
        .map(|path| path.strip_prefix(&root).unwrap().to_path_buf())
        .collect::<Vec<_>>();
    assert_eq!(
        native_imports,
        vec![PathBuf::from(
            "toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
        )]
    );

    let target = fs::read_to_string(
        root.join("toolkit/Sources/LocalAgentLLMCore/LLMTarget.swift"),
    )
    .unwrap();
    let configuration = fs::read_to_string(
        root.join("toolkit/Sources/LocalAgentLLMCore/AgentHostConfiguration.swift"),
    )
    .unwrap();
    let runtime = fs::read_to_string(
        root.join("toolkit/Sources/LocalAgentLLMLocal/LocalModelRuntime.swift"),
    )
    .unwrap();
    assert!(target.contains("case local(installationID: String)"));
    assert!(!configuration.contains("modelPath"));
    assert!(!configuration.contains("artifactPaths"));
    let prepare_start = runtime.find("public func prepareSession(").unwrap();
    let prepare_end = runtime[prepare_start..]
        .find("async throws -> PreparedLocalSession {")
        .map(|offset| prepare_start + offset)
        .unwrap();
    let prepare_api = &runtime[prepare_start..prepare_end];
    assert!(prepare_api.contains("hostConfiguration: AgentHostConfiguration"));
    assert!(prepare_api.contains("target: LLMTargetRevision"));
    assert!(!prepare_api.contains("targetDefaults:"));
    assert!(!prepare_api.contains("hostOverrides:"));

    let production_swift = source_files(&root.join("apps/LocalAgentApp/LocalAgentApp"), &["swift"])
        .into_iter()
        .chain(source_files(&swift_sources, &["swift"]))
        .collect::<Vec<_>>();
    let epoch_generators = production_swift
        .iter()
        .filter(|path| {
            fs::read_to_string(path)
                .unwrap()
                .contains("HostProcessEpoch.generate()")
        })
        .map(|path| path.strip_prefix(&root).unwrap().to_path_buf())
        .collect::<Vec<_>>();
    assert_eq!(
        epoch_generators,
        vec![PathBuf::from(
            "apps/LocalAgentApp/LocalAgentApp/App/LocalAgentApp.swift"
        )]
    );
    assert!(!runtime.contains("HostProcessEpoch.generate"));
    let subsystem = fs::read_to_string(
        root.join("toolkit/Sources/LocalAgentLLMLocal/LocalLLMSubsystem.swift"),
    )
    .unwrap();
    assert!(!subsystem.contains("HostProcessEpoch.generate"));
}

#[test]
fn cpp_and_artifact_link_ownership_remain_provider_neutral() {
    let root = repository_root();
    let package = fs::read_to_string(root.join("toolkit/Package.swift")).unwrap();
    assert_eq!(package.matches(".binaryTarget(").count(), 1);
    assert!(package.contains("path: \"Artifacts/LocalAgentInferenceNative.xcframework\""));
    assert!(!package.contains("../artifacts/"));

    let build = fs::read_to_string(root.join("rust-core/build.rs")).unwrap();
    assert!(build.contains("cargo:rustc-link-lib=static:-bundle=local_agent_inference_native"));
    assert!(!build.contains("Command::new"));
    assert!(!build.contains("cc::Build"));

    let forbidden_cpp = [
        "URLSession",
        "OfficialModelCatalog",
        "SQLite",
        "Keychain",
        "APIKey",
        "downloadURL",
    ];
    let cpp_roots = [
        root.join("inference/c_api"),
        root.join("inference/core"),
        root.join("inference/backends"),
    ];
    let mut findings = Vec::new();
    for cpp_root in cpp_roots {
        for path in source_files(&cpp_root, &["h", "hpp", "c", "cc", "cpp"]) {
            let source = fs::read_to_string(&path).unwrap();
            for symbol in forbidden_cpp {
                if source.contains(symbol) {
                    findings.push(format!("{}: {symbol}", path.display()));
                }
            }
        }
    }
    assert!(
        findings.is_empty(),
        "C++ must remain an inference-only boundary:\n{}",
        findings.join("\n")
    );
}

#[test]
fn release_catalog_and_phase_two_verification_entrypoints_are_frozen() {
    let root = repository_root();
    let release: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("inference/release-engines.json")).unwrap(),
    )
    .unwrap();
    let release_ids = release["engine_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap().to_string())
        .collect::<BTreeSet<_>>();
    let catalog: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join(
            "toolkit/Sources/LocalAgentLLMLocal/Resources/OfficialLocalModelCatalog.v1.json",
        ))
        .unwrap(),
    )
    .unwrap();
    let catalog_ids = catalog["signed"]["models"]
        .as_array()
        .unwrap()
        .iter()
        .map(|model| model["engine_id"].as_str().unwrap().to_string())
        .collect::<BTreeSet<_>>();
    assert!(!release_ids.is_empty());
    assert_eq!(release_ids, catalog_ids);

    let runner = fs::read_to_string(root.join("scripts/run-llm-phase-2-contracts.sh"))
        .expect("Task 10 must provide one deterministic Phase 2 runner");
    for command in [
        "build-local-agent-inference-xcframework.sh",
        "run-llm-phase-1-contracts.sh",
        "run-local-inference-cpp-contracts.sh",
        "llm_phase_two_architecture",
        "XcodeDefault.xctoolchain/usr/bin/swift",
        "test --disable-sandbox",
        "test-local-inference-app-link.sh",
        "--require-catalog-resources",
    ] {
        assert!(runner.contains(command), "Phase 2 runner is missing {command}");
    }
    assert!(!runner.contains("curl "));

    let project = fs::read_to_string(
        root.join("apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj"),
    )
    .unwrap();
    assert!(project.contains("LocalInferenceReleaseSmokeTests.swift in Sources"));
    let scheme = fs::read_to_string(root.join(
        "apps/LocalAgentApp/LocalAgentApp.xcodeproj/xcshareddata/xcschemes/LocalAgentApp.xcscheme",
    ))
    .unwrap();
    assert!(scheme.contains("LOCAL_AGENT_RUN_PHASE2_RELEASE_SMOKE"));
    assert!(scheme.contains("LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT"));
    assert!(scheme.contains("<MacroExpansion>"));
    assert!(scheme.contains("shouldUseLaunchSchemeArgsEnv = \"NO\""));

    let release_smoke =
        fs::read_to_string(root.join("scripts/run-llm-phase-2-release-smoke.sh")).unwrap();
    assert!(release_smoke.contains(
        "-only-testing:LocalAgentAppTests/LocalInferenceReleaseSmokeTests"
    ));
    assert!(release_smoke.contains("totalTestCount"));
    assert!(release_smoke.contains("ENABLE_TESTABILITY=YES"));
    assert!(release_smoke.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG"));

    let design = fs::read_to_string(root.join(
        "docs/superpowers/specs/2026-07-10-swift-llm-system-design.md",
    ))
    .unwrap();
    assert!(design.contains("Phase 2 implementation evidence (2026-07-15)"));
    for future in ["Phase 3", "Phase 4", "Phase 5"] {
        assert!(design.contains(future));
    }
}
