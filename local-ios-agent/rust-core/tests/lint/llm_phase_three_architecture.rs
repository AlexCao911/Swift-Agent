use std::{fs, path::{Path, PathBuf}};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust-core must be below the repository root")
        .to_path_buf()
}

fn files(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    fn visit(path: &Path, extensions: &[&str], output: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(path) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if matches!(
                    path.file_name().and_then(|name| name.to_str()),
                    Some("target" | ".build" | "Artifacts" | "vendor" | "third_party")
                ) {
                    continue;
                }
                visit(&path, extensions, output);
            } else if path.extension().and_then(|value| value.to_str())
                .is_some_and(|value| extensions.contains(&value))
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
fn llm_phase_three_architecture_keeps_rust_v2_provider_neutral() {
    let root = root();
    let v2 = root.join("rust-core/src/llm_contracts");
    let forbidden = [
        "ProviderProfile", "provider_profile", "BaseURL", "base_url", "APIKey",
        "api_key", "OpenAI", "Anthropic", "Gemini", "Grok", "DeepSeek",
        "MiniMax", "GLM", "CloudProviderAdapter", "URLSession",
    ];
    let mut findings = Vec::new();
    for path in files(&v2, &["rs"]) {
        let source = fs::read_to_string(&path).unwrap();
        for token in forbidden {
            if source.contains(token) {
                findings.push(format!("{}: {token}", path.display()));
            }
        }
    }
    assert!(
        findings.is_empty(),
        "Rust host-slot V2 contracts must not acquire Swift Provider semantics:\n{}",
        findings.join("\n")
    );

    let allowlist = fs::read_to_string(
        root.join("rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt"),
    ).unwrap();
    assert_eq!(
        allowlist.lines().filter(|line| !line.starts_with('#') && !line.is_empty()).count(),
        16,
        "Phase 3 must not grow the temporary legacy Rust LLM allowlist"
    );
    let resolver = fs::read_to_string(root.join("rust-core/src/run_snapshot/resolver.rs")).unwrap();
    assert!(resolver.contains("execution.host_slot_v2_not_runnable"));
}

#[test]
fn llm_phase_three_architecture_freezes_swift_credential_egress_and_transport_boundaries() {
    let root = root();
    let cloud = root.join(format!("toolkit/Sources/{}", ["LocalAgent", "LLMCloud"].concat()));
    let transport_path = cloud.join("CloudHTTPTransport.swift");
    let vault_path = cloud.join("SecurityCredentialVault.swift");
    let mut direct_session = Vec::new();
    let mut direct_keychain = Vec::new();
    for path in files(&cloud, &["swift"]) {
        let source = fs::read_to_string(&path).unwrap();
        if path != transport_path
            && (source.contains("URLSession(") || source.contains("URLSessionConfiguration"))
        {
            direct_session.push(path.strip_prefix(&root).unwrap().display().to_string());
        }
        if path != vault_path
            && ["SecItemAdd", "SecItemUpdate", "SecItemCopyMatching", "SecItemDelete"]
                .iter().any(|token| source.contains(token))
        {
            direct_keychain.push(path.strip_prefix(&root).unwrap().display().to_string());
        }
        for field in ["public let apiKey", "public var apiKey", "public let api_key", "public var api_key"] {
            assert!(!source.contains(field), "public/Codable API-key field found in {}", path.display());
        }
    }
    assert!(direct_session.is_empty(), "direct URLSession users: {direct_session:?}");
    assert!(direct_keychain.is_empty(), "direct Keychain users: {direct_keychain:?}");

    let transport = fs::read_to_string(&transport_path).unwrap();
    assert!(transport.contains("_ request: AuthorizedCloudHTTPRequest"));
    assert!(!transport.contains("_ request: CloudWireRequest"));
    let validator = fs::read_to_string(cloud.join("CloudSemanticTurnValidator.swift")).unwrap();
    assert!(validator.contains("fileprivate init("));
    let egress = fs::read_to_string(cloud.join("ProviderEgressPolicy.swift")).unwrap();
    assert!(egress.contains("package struct AuthorizedCloudHTTPRequest"));
    assert!(egress.contains("fileprivate init("));
    let runtime = fs::read_to_string(cloud.join("CloudLLMRuntime.swift")).unwrap();
    assert!(runtime.contains("private var active: ActiveSession?"));
    assert!(runtime.contains("while attempts < 2"));
    assert!(!runtime.contains("LocalAgentLLMLocal"));
}

#[test]
fn llm_phase_three_architecture_keeps_cpp_cloud_free() {
    let root = root();
    let forbidden = [
        "CloudProvider", "ProviderProfile", "URLSession", "Keychain", "APIKey",
        "api_key", "OpenAI", "Anthropic", "Gemini", "DeepSeek", "MiniMax",
    ];
    let mut findings = Vec::new();
    for directory in ["inference/c_api", "inference/core", "inference/backends"] {
        for path in files(&root.join(directory), &["h", "hpp", "c", "cc", "cpp"]) {
            let source = fs::read_to_string(&path).unwrap();
            for token in forbidden {
                if source.contains(token) {
                    findings.push(format!("{}: {token}", path.display()));
                }
            }
        }
    }
    assert!(findings.is_empty(), "C++ must remain local-inference-only:\n{}", findings.join("\n"));
}

#[test]
fn llm_phase_three_architecture_requires_all_provider_fixtures_and_one_runner() {
    let root = root();
    let tests = root.join(format!(
        "toolkit/Tests/{}Tests",
        ["LocalAgent", "LLMCloud"].concat()
    ));
    for (suite, fixture) in [
        ("OpenAIResponsesAdapterTests.swift", "openai"),
        ("AnthropicMessagesAdapterTests.swift", "anthropic"),
        ("GeminiInteractionsAdapterTests.swift", "gemini"),
        ("XAIAdapterTests.swift", "xai"),
        ("DeepSeekAdapterTests.swift", "deepseek"),
        ("MiniMaxAdapterTests.swift", "minimax"),
        ("GLMAdapterTests.swift", "glm"),
    ] {
        assert!(tests.join(suite).is_file(), "missing provider adapter suite {suite}");
        let count = files(&tests.join("Fixtures").join(fixture), &["sse", "json"]).len();
        assert!(count > 0, "provider fixture directory {fixture} is empty");
    }
    let preset = fs::read_to_string(
        root.join(format!(
            "toolkit/Sources/{}/ProviderPreset.swift",
            ["LocalAgent", "LLMCloud"].concat()
        )),
    ).unwrap();
    assert!(preset.contains("public static let shipped"));
    let runtime_tests = fs::read_to_string(tests.join("CloudLLMRuntimeTests.swift")).unwrap();
    assert!(runtime_tests.contains("adapterIDs.count == 7"));

    let runner = fs::read_to_string(root.join("scripts/run-llm-phase-3-contracts.sh"))
        .expect("Phase 3 deterministic runner is missing");
    for required in [
        "run-llm-phase-2-contracts.sh", "llm_phase_three_architecture",
        "swift", "test", "CloudCredentialKeychainTests",
        "LOCAL_AGENT_PHASE3_SIMULATOR_UDID", "platform=iOS Simulator,id=$SIMULATOR_UDID",
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "XAI_API_KEY",
        "DEEPSEEK_API_KEY", "MINIMAX_API_KEY", "ZHIPUAI_API_KEY",
    ] {
        assert!(runner.contains(required), "Phase 3 runner is missing {required}");
    }
    assert!(!runner.contains("name=iPhone 17 Pro"));
    assert!(!runner.contains("run-llm-phase-3-live-smoke.sh"));
    let live_smoke = fs::read_to_string(root.join("scripts/run-llm-phase-3-live-smoke.sh"))
        .expect("Phase 3 live-smoke runner is missing");
    let secret_rejection = live_smoke.find("*_API_KEY|*_TOKEN|*_SECRET)").unwrap();
    let scoped_allow = live_smoke.find("LOCAL_AGENT_CLOUD_SMOKE_*)").unwrap();
    assert!(
        secret_rejection < scoped_allow,
        "secret-shaped variables must be rejected before the live-smoke namespace is allowed"
    );
    let design = fs::read_to_string(
        root.join("docs/superpowers/specs/2026-07-10-swift-llm-system-design.md"),
    ).unwrap();
    assert!(design.contains("Phase 3 implementation evidence (2026-07-18)"));
    assert!(design.contains("Phase 4"));
    assert!(design.contains("Phase 5"));
}
