use std::fs;
use std::path::{Path, PathBuf};

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
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
