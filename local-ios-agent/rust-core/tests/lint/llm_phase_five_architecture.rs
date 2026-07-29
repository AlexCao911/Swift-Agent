use std::{
    fs,
    path::{Path, PathBuf},
};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn read(relative: &str) -> String {
    fs::read_to_string(root().join(relative)).unwrap()
}

fn rust_product_sources() -> String {
    fn visit(path: &Path, sources: &mut String) {
        for entry in fs::read_dir(path).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                visit(&path, sources);
            } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
                let relative = path
                    .strip_prefix(root())
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/");
                if matches!(
                    relative.as_str(),
                    "rust-core/src/migration/legacy_agent_profile_translator.rs"
                        | "rust-core/src/agent_package/reader.rs"
                ) {
                    continue;
                }
                sources.push_str(&format!("\n// {relative}\n"));
                sources.push_str(&fs::read_to_string(path).unwrap());
            }
        }
    }

    let mut sources = String::new();
    visit(&root().join("rust-core/src"), &mut sources);
    sources
}

fn assert_no_occurrence(source: &str, forbidden: &str) {
    assert!(
        !source.contains(forbidden),
        "forbidden legacy LLM ownership remains: {forbidden}"
    );
}

#[test]
fn rust_product_has_no_llm_provider_or_engine_ownership() {
    let production = rust_product_sources();
    for forbidden in [
        "ModelProvider",
        "ProviderRegistry",
        "ProviderProfile",
        "ProviderAccount",
        "ModelBinding",
        "InferenceBackend",
        "InferenceRouter",
        "LocalLLMProvider",
        "OpenAI",
        "base_url",
        "api_key",
        "credential_ref",
        "model_path",
    ] {
        assert_no_occurrence(&production, forbidden);
    }
}

#[test]
fn rust_profile_snapshot_and_bridge_are_v2_only() {
    assert_no_occurrence(
        &read("rust-core/src/user_customization/agent_profile.rs"),
        "LegacyV1",
    );
    assert_no_occurrence(
        &read("rust-core/src/run_snapshot/resolved_bindings.rs"),
        "ResolvedModelBinding",
    );
    assert_no_occurrence(
        &read("rust-core/src/ffi_bridge.rs"),
        "profile_execution_route_json",
    );
}

#[test]
fn retained_legacy_translator_is_not_an_execution_or_provider_boundary() {
    let migration = read("rust-core/src/migration/legacy_agent_profile_translator.rs");
    for forbidden in [
        "ModelBinding",
        "ModelProvider",
        "ProviderRegistry",
        "ProviderAccount",
        "credential_ref",
        "base_url",
        "api_key",
        "model_path",
        "InferenceRouter",
        "start_run",
        "send_message",
    ] {
        assert_no_occurrence(&migration, forbidden);
    }
}

#[test]
fn public_agent_package_contract_has_no_concrete_model_binding() {
    let manifest = read("rust-core/src/agent_package/manifest.rs");
    let reader = read("rust-core/src/agent_package/reader.rs");
    let module = read("rust-core/src/agent_package/mod.rs");
    for forbidden in ["PackageModelBinding", "credential_ref", "local_path"] {
        assert_no_occurrence(&manifest, forbidden);
    }
    for forbidden in ["PackageModelBinding", "crate::model", "ModelProvider"] {
        assert_no_occurrence(&reader, forbidden);
    }
    assert_no_occurrence(&module, "PackageModelBinding");
}

#[test]
fn swift_bridge_and_app_bootstrap_have_no_legacy_runtime_configuration() {
    let bridge = read("toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift");
    let c_header = read("toolkit/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h");
    let bootstrap = read("apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift");
    let combined = format!("{bridge}\n{c_header}\n{bootstrap}");
    for forbidden in [
        "RustRuntimeProviderConfiguration",
        "simulatorProviders",
        "setProvider",
        "sendMessageStreaming",
        "profileExecutionRoute",
    ] {
        assert_no_occurrence(&combined, forbidden);
    }
}
