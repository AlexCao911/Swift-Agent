use std::fs;
use std::path::{Path, PathBuf};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn rust_sources(root: &Path) -> Vec<PathBuf> {
    fn visit(path: &Path, output: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                visit(&path, output);
            } else if path.extension().and_then(|value| value.to_str()) == Some("rs") {
                output.push(path);
            }
        }
    }
    let mut output = Vec::new();
    visit(root, &mut output);
    output
}

#[test]
fn v2_snapshot_binding_is_tagged_and_provider_neutral() {
    let root = root();
    let snapshot = fs::read_to_string(root.join("rust-core/src/run_snapshot/snapshot.rs")).unwrap();
    let bindings =
        fs::read_to_string(root.join("rust-core/src/run_snapshot/resolved_bindings.rs")).unwrap();
    assert!(bindings.contains("pub enum ResolvedLLMBinding"));
    assert!(bindings.contains("HostSlotV2(ResolvedHostSlotBinding)"));
    assert!(bindings.contains("pub struct OpaqueHostBindingCrossLink"));
    assert!(snapshot.contains("llm_binding: ResolvedLLMBinding"));
    let snapshot_fields = snapshot
        .split("pub struct ResolvedRunSnapshot")
        .nth(1)
        .unwrap()
        .split('}')
        .next()
        .unwrap();
    assert!(!snapshot_fields.contains("model_binding: ResolvedModelBinding"));
    assert!(!snapshot_fields.contains("trusted_host_state: TrustedHostRunState"));

    let persisted_binding = snapshot
        .split("pub enum PersistedResolvedLLMBinding")
        .nth(1)
        .expect("persisted tagged binding must exist")
        .split("pub struct PersistedLegacyModelBinding")
        .next()
        .unwrap();
    let host_variant = persisted_binding
        .split("HostSlotV2 {")
        .nth(1)
        .expect("host V2 persisted variant must exist")
        .split("},")
        .next()
        .unwrap();
    for forbidden in [
        "provider_account_id",
        "provider_id",
        "model_id",
        "credential",
        "base_url",
        "installation_path",
        "adapter",
    ] {
        assert!(
            !host_variant.contains(forbidden),
            "host V2 persisted binding contains {forbidden}"
        );
    }
    assert!(persisted_binding.contains("LegacyV1"));
    assert!(snapshot.contains("pub struct PersistedLegacyModelBinding"));
    assert!(snapshot.contains("provider_account_id: String"));
    assert!(snapshot.contains("PersistedResolvedRunSnapshotV2::try_from(self)"));
}

#[test]
fn production_bridge_uses_unified_phase_c_and_reconciliation_authority() {
    let root = root();
    let bridge = fs::read_to_string(root.join("rust-core/src/ffi_bridge.rs")).unwrap();
    let preparation =
        fs::read_to_string(root.join("rust-core/src/run_snapshot/snapshot_service.rs")).unwrap();
    assert!(bridge.contains("RunPreparationService::with_host_runtime"));
    assert!(bridge.contains("pub fn reconcile_preparation_json"));
    assert!(!bridge.contains("format!(\"{path}.agent-os\")"));
    assert!(preparation.contains("commit_prepared_host_run(PreparedHostRunCommit"));
    assert!(preparation.contains("resolved-run-snapshot:v1"));
    assert!(!preparation.contains("execution.host_slot_v2_not_runnable"));
}

#[test]
fn production_route_is_enabled_without_growing_the_legacy_allowlist() {
    let root = root();
    let rust_root = root.join("rust-core/src");
    for path in rust_sources(&rust_root) {
        let source = fs::read_to_string(&path).unwrap();
        assert!(
            !source.contains("execution.host_slot_v2_not_runnable"),
            "obsolete Phase 3 blocker remains in {}",
            path.display()
        );
    }

    let resolver = fs::read_to_string(rust_root.join("run_snapshot/resolver.rs")).unwrap();
    let bridge = fs::read_to_string(rust_root.join("ffi_bridge.rs")).unwrap();
    assert!(resolver.contains("pub struct ProfileExecutionRoute"));
    assert!(resolver.contains("execution.host_slot_v2_requires_preparation"));
    assert!(bridge.contains("profile_execution_route_json"));
    assert!(bridge.contains("local_agent_runtime_bridge_profile_execution_route"));

    let allowlist = fs::read_to_string(
        root.join("rust-core/tests/fixtures/architecture/legacy_llm_allowlist.txt"),
    )
    .unwrap();
    assert_eq!(
        allowlist
            .lines()
            .filter(|line| !line.starts_with('#') && !line.is_empty())
            .count(),
        16,
        "Phase 4 must not grow the temporary legacy Rust LLM allowlist"
    );
}

#[test]
fn phase_four_runner_is_deterministic_and_secret_free() {
    let runner =
        fs::read_to_string(root().join("scripts/run-llm-phase-4-contracts.sh")).unwrap();
    for required in [
        "run-llm-phase-3-contracts.sh",
        "--test contract",
        "--test integration",
        "llm_phase_four_architecture",
        "LOCAL_AGENT_PHASE4_IPHONE_UDID",
        "LOCAL_AGENT_PHASE4_IPAD_UDID",
        "LLMHostCompositionTests",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GEMINI_API_KEY",
        "XAI_API_KEY",
        "DEEPSEEK_API_KEY",
        "MINIMAX_API_KEY",
        "ZHIPUAI_API_KEY",
    ] {
        assert!(runner.contains(required), "Phase 4 runner is missing {required}");
    }
    assert!(
        runner.find("run-llm-phase-3-contracts.sh")
            < runner.find("--test contract"),
        "Phase 4 must run the Phase 3 gate first"
    );
    assert!(!runner.contains("run-llm-phase-3-live-smoke.sh"));
}
