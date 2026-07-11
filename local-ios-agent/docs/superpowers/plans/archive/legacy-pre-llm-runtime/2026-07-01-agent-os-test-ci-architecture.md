# Agent OS Test And CI Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-grade Agent OS test net before Plan03b: shared realistic fixtures, cross-module contract tests, lifecycle integration tests, golden artifact tests, architecture lint tests, and CI gates. Restructuring existing tests into unit/contract/integration/golden/lint is part of the work, but the main deliverable is more rigorous production test code that prevents module collaboration drift.

**Architecture:** Rust integration tests will use Cargo-discovered top-level harness files (`unit.rs`, `contract.rs`, `integration.rs`, `golden.rs`, `lint.rs`) with module files under matching directories. Shared production-like builders live under `tests/support/` and are used by contract/integration/golden tests instead of one-off fixtures. CI will run these layers in order: fast local module checks first, cross-module contracts next, golden/lint gates, then lifecycle integration and Swift bridge checks. The migration keeps current behavior green while adding new gates for package -> profile -> binding, tool -> security -> execution, model -> security -> inference, storage transaction atomicity, and stable debug artifacts.

**Tech Stack:** Rust 2021, Cargo integration tests, Swift Package Manager, GitHub Actions, bash CI scripts, existing `local_ios_agent_runtime` and `LocalAgentToolkit` packages.

---

## Current State

The current Rust test tree has many top-level integration test files under `local-ios-agent/rust-core/tests/`. Cargo runs them all, but their layer is implicit:

- Unit-like module tests: `core_types.rs`, `context_budget.rs`, `stream_batcher.rs`, `tool_parser.rs`, `sqlite_store.rs`, `memory_foundation.rs`.
- Cross-slice contract tests: `agent_package_agent_os.rs`, `agent_builder_agent_os.rs`, `model_provider_agent_os.rs`, `security_data_egress.rs`, `storage_transaction.rs`, `tool_recipe_agent_os.rs`.
- Runtime lifecycle tests: `agent_loop.rs`, `runtime_mock.rs`, `runtime_replay.rs`, `runtime_tool_orchestration.rs`, `ffi_bridge.rs`.
- Golden-ish tests are mixed into contract tests through `tests/fixtures`.
- Architecture lint tests exist in `architecture_agent_os.rs`, but no CI job runs them as a named gate.
- Existing tests mostly validate local behavior. They do not yet provide enough production-like lifecycle coverage for package install -> profile persistence -> binding readiness, authorized tool execution, remote model egress, archive/event/checkpoint atomicity, or stable debug output.
- There is no `.github/workflows` directory in the repo.

Cargo detail that matters: nested files under `tests/unit/*.rs` do not run automatically. Each test layer must have a top-level Cargo test target such as `tests/unit.rs` declaring `mod core_types;`, which loads `tests/unit/core_types.rs`.

Harness detail that also matters: a top-level integration test file like `tests/unit.rs` does not resolve `mod approval;` to `tests/unit/approval.rs`. Use explicit path attributes such as `#[path = "unit/approval.rs"] mod approval;`.

## Target File Structure

```text
local-ios-agent/rust-core/tests/
  unit.rs
  unit/
    approval.rs
    context_budget.rs
    context_compaction.rs
    context_projection.rs
    context_prompt.rs
    core_types.rs
    desktop_minicpm_provider.rs
    desktop_minicpm_transport.rs
    local_llm_backend.rs
    local_llm_provider.rs
    memory_foundation.rs
    mock_provider.rs
    provider_registry.rs
    run_state.rs
    session_tree.rs
    sqlite_store.rs
    stream_batcher.rs
    tool_parser.rs
    tool_registry.rs
    tool_router.rs
  contract.rs
  contract/
    agent_builder_agent_os.rs
    agent_profile_contract.rs
    agent_package_agent_os.rs
    package_profile_contract.rs
    inference_backend_agent_os.rs
    memory_agent_os.rs
    model_provider_agent_os.rs
    model_inference_security_contract.rs
    prompt_archive_agent_os.rs
    protocol_dto_unknown.rs
    protocol_lifecycle.rs
    protocol_plugin_module.rs
    protocol_registry.rs
    security_approval_protocol.rs
    security_data_egress.rs
    security_manager.rs
    storage_transaction.rs
    tool_security_contract.rs
    tool_recipe_agent_os.rs
    user_component.rs
  integration.rs
  integration/
    agent_lifecycle_failure_paths.rs
    agent_lifecycle_profile_to_runtime.rs
    agent_loop.rs
    ffi_bridge.rs
    ffi_streaming_events.rs
    openai_chat_adapter.rs
    runtime_mock.rs
    runtime_provider_selection.rs
    runtime_provider_streaming.rs
    runtime_replay.rs
    runtime_tool_orchestration.rs
  golden.rs
  golden/
    agent_package_export.rs
    dto_unknown.rs
    lifecycle_debug_artifacts.rs
    user_component_dto.rs
  lint.rs
  lint/
    architecture_agent_os.rs
    test_taxonomy.rs
  support/
    mod.rs
    agent_os_fixtures.rs
    assertions.rs
  fixtures/
    agent_package/
    golden/
      lifecycle/
    user_component/
```

CI and docs:

```text
.github/workflows/agent-os-ci.yml
scripts/ci/rust-unit.sh
scripts/ci/rust-contract.sh
scripts/ci/rust-golden.sh
scripts/ci/rust-lint.sh
scripts/ci/rust-integration.sh
scripts/ci/swift-bridge.sh
scripts/ci/agent-os-all.sh
local-ios-agent/docs/testing/agent-os-test-architecture.md
```

---

## Production Test Matrix

These tests are the reason for this plan. File taxonomy and CI scripts are supporting work.

| Layer | Test file | Production boundary locked |
| --- | --- | --- |
| Contract | `tests/contract/package_profile_contract.rs` | Package install must create a persisted, version-pinned `AgentProfile` that can pass the same readiness rules as Agent Builder output. |
| Contract | `tests/contract/package_profile_contract.rs` | Package-installed model binding must be registered in the model binding catalog and linked to local credential bindings. |
| Contract | `tests/contract/agent_profile_contract.rs` | Published profiles reject missing required slots, duplicate slot bindings, non-existent component versions, and non-pinnable model selections. |
| Contract | `tests/contract/tool_security_contract.rs` | HTTP tool routing must use injected `SecurityManager`, return an authorized request with private security metadata, and reject execution without matching egress grant. |
| Contract | `tests/contract/model_inference_security_contract.rs` | Remote model validation/listing/inference must use operation-bound `DataEgressDecision` and matching `ApprovalGrant`; local providers must not fabricate egress decisions. |
| Contract | `tests/contract/storage_transaction.rs` | Component publish, profile publish, package install, archive write, and event append must share UnitOfWork semantics and fail all-or-nothing in injected failure cases. |
| Integration | `tests/integration/agent_lifecycle_profile_to_runtime.rs` | A realistic agent package can install, resolve a profile, validate bindings, assemble prompt/tool/memory/model readiness, and produce a runtime-ready plan input. |
| Integration | `tests/integration/agent_lifecycle_failure_paths.rs` | Invalid local credential binding, denied egress destination, missing required component, stale model catalog version, and duplicate slot binding fail before Runtime. |
| Golden | `tests/golden/lifecycle_debug_artifacts.rs` | Package export, profile snapshot preview, prompt archive, event stream, and tool request debug envelopes have stable redacted JSON/YAML output. |
| Lint | `tests/lint/architecture_agent_os.rs` | Runtime must not depend on Agent Builder, package install, profile repository, or component catalog modules. |

The production tests should prefer real public APIs and in-memory production repositories over hand-built structs. When a direct struct constructor would bypass normal validation, the test must use the same application service entry point that Swift or Runtime would use.

### Task 0: Add Shared Production Test Fixtures

**Files:**
- Create: `local-ios-agent/rust-core/tests/support/mod.rs`
- Create: `local-ios-agent/rust-core/tests/support/agent_os_fixtures.rs`
- Create: `local-ios-agent/rust-core/tests/support/assertions.rs`

- [ ] **Step 1: Create support module**

Create `local-ios-agent/rust-core/tests/support/mod.rs`:

```rust
pub mod agent_os_fixtures;
pub mod assertions;
```

- [ ] **Step 2: Add production-like fixture builders**

Create `local-ios-agent/rust-core/tests/support/agent_os_fixtures.rs` with builders that create complete, valid objects through public services:

```rust
use std::sync::Arc;

use local_ios_agent_runtime::agent_package::{
    AgentPackageInstaller, AgentPackageManifest, InMemoryPackageInstallStore, LocalBindings,
};
use local_ios_agent_runtime::model::InMemoryModelBindingCatalog;
use local_ios_agent_runtime::security::{SecurityManager, StaticSecurityPermissionService};
use local_ios_agent_runtime::storage::InMemoryTransactionRunner;
use local_ios_agent_runtime::user_customization::{
    ComponentCatalogService, InMemoryAgentProfileRepository,
};

#[derive(Clone)]
pub struct AgentOsTestWorld {
    pub package_store: InMemoryPackageInstallStore,
    pub profile_repository: InMemoryAgentProfileRepository,
    pub model_catalog: InMemoryModelBindingCatalog,
    pub component_catalog: ComponentCatalogService,
    pub security: SecurityManager,
}

impl AgentOsTestWorld {
    pub fn new() -> Self {
        let permission_service = Arc::new(
            StaticSecurityPermissionService::default()
                .allow_destination("https://api.openai.com")
                .allow_destination("https://memory.example.com"),
        );

        Self {
            package_store: InMemoryPackageInstallStore::default(),
            profile_repository: InMemoryAgentProfileRepository::default(),
            model_catalog: InMemoryModelBindingCatalog::default(),
            component_catalog: ComponentCatalogService::default(),
            security: SecurityManager::with_permission_service(permission_service),
        }
    }

    pub fn package_installer(&self) -> AgentPackageInstaller {
        AgentPackageInstaller::new(
            Box::new(InMemoryTransactionRunner::default()),
            self.package_store.clone(),
            self.profile_repository.clone(),
            self.model_catalog.clone(),
        )
    }

    pub fn install_fixture_package(&self) -> local_ios_agent_runtime::agent_package::InstalledAgentPackage {
        self.package_installer()
            .install(
                AgentPackageManifest::fixture_valid(),
                LocalBindings::empty().with_credential_ref(
                    "model.account",
                    "credential.openai.default",
                    "sha256:local-binding",
                ),
            )
            .unwrap()
    }
}
```

Before writing this file, verify the concrete constructor signatures in `src/` and use the current production APIs. Do not create test-only bypass constructors.

- [ ] **Step 3: Add assertion helpers**

Create `local-ios-agent/rust-core/tests/support/assertions.rs`:

```rust
pub fn assert_error_code(error: &local_ios_agent_runtime::AgentError, expected: &str) {
    assert_eq!(error.code(), expected, "unexpected error: {error:?}");
}

pub fn assert_redacted_debug_output(value: &str) {
    for forbidden in ["sk-", "api_key", "secret", "token", "password"] {
        assert!(
            !value.to_lowercase().contains(forbidden),
            "debug output leaked forbidden marker {forbidden}: {value}"
        );
    }
}
```

- [ ] **Step 4: Wire support modules into non-unit harnesses**

Each harness that needs shared fixtures declares:

```rust
mod support;
```

For `tests/contract.rs`, `tests/integration.rs`, and `tests/golden.rs`, use:

```rust
#[path = "support/mod.rs"]
mod support;
```

- [ ] **Step 5: Verify support compiles through the first real contract test**

Wire `tests/contract/package_profile_contract.rs` with the first package/profile contract test from Task 2.5, then compile the contract harness.

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract
```

Expected: support compiles and no warnings introduce dead test-only APIs in production modules.

### Task 1: Add Test Taxonomy Harnesses And Lint Gate

**Files:**
- Create: `local-ios-agent/rust-core/tests/unit.rs`
- Create: `local-ios-agent/rust-core/tests/contract.rs`
- Create: `local-ios-agent/rust-core/tests/integration.rs`
- Create: `local-ios-agent/rust-core/tests/golden.rs`
- Create: `local-ios-agent/rust-core/tests/lint.rs`
- Create: `local-ios-agent/rust-core/tests/lint/test_taxonomy.rs`
- Move later: `local-ios-agent/rust-core/tests/architecture_agent_os.rs` to `local-ios-agent/rust-core/tests/lint/architecture_agent_os.rs`

- [ ] **Step 1: Write failing lint test for taxonomy**

Create `local-ios-agent/rust-core/tests/lint/test_taxonomy.rs`:

```rust
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
            violations.push(format!("root test directory is not a taxonomy directory: {name}"));
        }
    }

    assert!(
        violations.is_empty(),
        "test taxonomy violations:\n{}",
        violations.join("\n")
    );
}
```

- [ ] **Step 2: Add lint harness**

Create `local-ios-agent/rust-core/tests/lint.rs`:

```rust
mod architecture_agent_os;
mod test_taxonomy;
```

For now leave `architecture_agent_os` unmoved so the test fails with `file not found`; that confirms the harness is active.

- [ ] **Step 3: Verify RED**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test lint
```

Expected: FAIL because `tests/lint/architecture_agent_os.rs` does not exist or because root-level test files violate the taxonomy.

- [ ] **Step 4: Add empty layer harnesses**

Create `local-ios-agent/rust-core/tests/unit.rs`:

```rust
#[path = "unit/approval.rs"]
mod approval;
#[path = "unit/context_budget.rs"]
mod context_budget;
// Continue with one explicit #[path = "unit/<file>.rs"] per unit module.
```

Create `local-ios-agent/rust-core/tests/contract.rs`:

```rust
#[path = "support/mod.rs"]
mod support;

#[path = "contract/agent_builder_agent_os.rs"]
mod agent_builder_agent_os;
#[path = "contract/agent_profile_contract.rs"]
mod agent_profile_contract;
// Continue with one explicit #[path = "contract/<file>.rs"] per contract module.
```

Create `local-ios-agent/rust-core/tests/integration.rs`:

```rust
#[path = "support/mod.rs"]
mod support;

#[path = "integration/agent_lifecycle_failure_paths.rs"]
mod agent_lifecycle_failure_paths;
#[path = "integration/agent_lifecycle_profile_to_runtime.rs"]
mod agent_lifecycle_profile_to_runtime;
// Continue with one explicit #[path = "integration/<file>.rs"] per integration module.
```

Create `local-ios-agent/rust-core/tests/golden.rs`:

```rust
#[path = "support/mod.rs"]
mod support;

#[path = "golden/agent_package_export.rs"]
mod agent_package_export;
#[path = "golden/dto_unknown.rs"]
mod dto_unknown;
#[path = "golden/lifecycle_debug_artifacts.rs"]
mod lifecycle_debug_artifacts;
#[path = "golden/user_component_dto.rs"]
mod user_component_dto;
```

- [ ] **Step 5: Verify harness compile failure is now about missing moved files**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test unit -- --skip localhost_transport_uses_content_length_and_does_not_wait_for_eof --test-threads=1
if [[ "${CODEX_SANDBOX_NETWORK_DISABLED:-0}" == "1" ]]; then
  echo "Skipping localhost socket unit test inside Codex network-disabled sandbox."
else
  cargo test --test unit localhost_transport_uses_content_length_and_does_not_wait_for_eof
fi
```

Expected: FAIL with module file not found, for example `file not found for module approval`.

---

### Task 2: Move Existing Rust Tests Into Layers

**Files:**
- Move current root test files into `tests/unit/`, `tests/contract/`, `tests/integration/`, `tests/lint/`
- Modify moved files with `include_str!` path updates
- Preserve: `local-ios-agent/rust-core/tests/fixtures/**`

- [ ] **Step 1: Move unit tests**

Run:

```bash
cd local-ios-agent/rust-core
mkdir -p tests/unit tests/contract tests/integration tests/golden tests/lint tests/support
git mv tests/approval.rs tests/unit/approval.rs
git mv tests/context_budget.rs tests/unit/context_budget.rs
git mv tests/context_compaction.rs tests/unit/context_compaction.rs
git mv tests/context_projection.rs tests/unit/context_projection.rs
git mv tests/context_prompt.rs tests/unit/context_prompt.rs
git mv tests/core_types.rs tests/unit/core_types.rs
git mv tests/desktop_minicpm_provider.rs tests/unit/desktop_minicpm_provider.rs
git mv tests/desktop_minicpm_transport.rs tests/unit/desktop_minicpm_transport.rs
git mv tests/local_llm_backend.rs tests/unit/local_llm_backend.rs
git mv tests/local_llm_provider.rs tests/unit/local_llm_provider.rs
git mv tests/memory_foundation.rs tests/unit/memory_foundation.rs
git mv tests/mock_provider.rs tests/unit/mock_provider.rs
git mv tests/provider_registry.rs tests/unit/provider_registry.rs
git mv tests/run_state.rs tests/unit/run_state.rs
git mv tests/session_tree.rs tests/unit/session_tree.rs
git mv tests/sqlite_store.rs tests/unit/sqlite_store.rs
git mv tests/stream_batcher.rs tests/unit/stream_batcher.rs
git mv tests/tool_parser.rs tests/unit/tool_parser.rs
git mv tests/tool_registry.rs tests/unit/tool_registry.rs
git mv tests/tool_router.rs tests/unit/tool_router.rs
```

- [ ] **Step 2: Move contract tests**

Run:

```bash
cd local-ios-agent/rust-core
git mv tests/agent_builder_agent_os.rs tests/contract/agent_builder_agent_os.rs
git mv tests/agent_package_agent_os.rs tests/contract/agent_package_agent_os.rs
git mv tests/inference_backend_agent_os.rs tests/contract/inference_backend_agent_os.rs
git mv tests/memory_agent_os.rs tests/contract/memory_agent_os.rs
git mv tests/model_provider_agent_os.rs tests/contract/model_provider_agent_os.rs
git mv tests/prompt_archive_agent_os.rs tests/contract/prompt_archive_agent_os.rs
git mv tests/protocol_dto_unknown.rs tests/contract/protocol_dto_unknown.rs
git mv tests/protocol_lifecycle.rs tests/contract/protocol_lifecycle.rs
git mv tests/protocol_plugin_module.rs tests/contract/protocol_plugin_module.rs
git mv tests/protocol_registry.rs tests/contract/protocol_registry.rs
git mv tests/security_approval_protocol.rs tests/contract/security_approval_protocol.rs
git mv tests/security_data_egress.rs tests/contract/security_data_egress.rs
git mv tests/security_manager.rs tests/contract/security_manager.rs
git mv tests/storage_transaction.rs tests/contract/storage_transaction.rs
git mv tests/tool_recipe_agent_os.rs tests/contract/tool_recipe_agent_os.rs
git mv tests/user_component.rs tests/contract/user_component.rs
```

- [ ] **Step 3: Move integration tests**

Run:

```bash
cd local-ios-agent/rust-core
git mv tests/agent_loop.rs tests/integration/agent_loop.rs
git mv tests/ffi_bridge.rs tests/integration/ffi_bridge.rs
git mv tests/ffi_streaming_events.rs tests/integration/ffi_streaming_events.rs
git mv tests/openai_chat_adapter.rs tests/integration/openai_chat_adapter.rs
git mv tests/runtime_mock.rs tests/integration/runtime_mock.rs
git mv tests/runtime_provider_selection.rs tests/integration/runtime_provider_selection.rs
git mv tests/runtime_provider_streaming.rs tests/integration/runtime_provider_streaming.rs
git mv tests/runtime_replay.rs tests/integration/runtime_replay.rs
git mv tests/runtime_tool_orchestration.rs tests/integration/runtime_tool_orchestration.rs
```

- [ ] **Step 4: Move lint test**

Run:

```bash
cd local-ios-agent/rust-core
git mv tests/architecture_agent_os.rs tests/lint/architecture_agent_os.rs
```

- [ ] **Step 5: Update relative `include_str!` paths**

Run this search:

```bash
cd local-ios-agent/rust-core
rg 'include_str!\("../src|include_str!\("fixtures/' tests
```

Make these edits:

```rust
// In moved tests/contract/agent_package_agent_os.rs:
include_str!("../fixtures/agent_package/valid/agent.yaml")
include_str!("../fixtures/agent_package/valid/model.yaml")

// In moved tests/contract/user_component.rs:
include_str!("../fixtures/user_component/component_content_v1.json")
include_str!("../fixtures/user_component/unknown_component_kind.json")

// In moved tests/lint/architecture_agent_os.rs:
include_str!("../../src/core/runtime.rs")
include_str!("../../src/user_customization/agent_profile.rs")

// In moved tests/contract/tool_recipe_agent_os.rs:
include_str!("../../src/security/manager.rs")
include_str!("../../src/tool/execution_request.rs")

// In moved tests/contract/agent_builder_agent_os.rs:
include_str!("../../src/user_customization/agent_template.rs")
include_str!("../../src/user_customization/agent_profile.rs")
include_str!("../../src/user_customization/agent_slot.rs")
include_str!("../../src/user_customization/builder_resolver.rs")
include_str!("../../src/user_customization/readiness.rs")

// In moved tests/contract/storage_transaction.rs:
include_str!("../../src/storage/transaction.rs")

// In moved tests/contract/inference_backend_agent_os.rs:
include_str!("../../src/inference/router.rs")
```

Do not rewrite paths that already use `env!("CARGO_MANIFEST_DIR")`; those are stable after moves.

- [ ] **Step 6: Verify each layer**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test unit
cargo test --test contract
cargo test --test integration
cargo test --test lint
```

Expected: unit/contract/integration/lint all PASS. `cargo test --test golden` still fails because golden files are not implemented yet.

- [ ] **Step 7: Commit migration**

Run:

```bash
git add local-ios-agent/rust-core/tests
git commit -m "test(agent-os): classify rust tests by layer"
```

---

### Task 2.5: Add Production Contract Tests

**Files:**
- Create: `local-ios-agent/rust-core/tests/contract/package_profile_contract.rs`
- Create: `local-ios-agent/rust-core/tests/contract/agent_profile_contract.rs`
- Create: `local-ios-agent/rust-core/tests/contract/tool_security_contract.rs`
- Create: `local-ios-agent/rust-core/tests/contract/model_inference_security_contract.rs`
- Modify: `local-ios-agent/rust-core/tests/contract/storage_transaction.rs`
- Modify: `local-ios-agent/rust-core/tests/contract.rs`

- [ ] **Step 1: Add package -> profile contract tests**

Create `local-ios-agent/rust-core/tests/contract/package_profile_contract.rs`:

```rust
use crate::support::agent_os_fixtures::AgentOsTestWorld;

#[test]
fn package_install_creates_profile_that_is_version_pinned_and_repository_resolvable() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();

    let profile_ref = installed.profile();
    assert!(profile_ref.version().is_some(), "installed profile must be pinned");

    let profile = world
        .profile_repository
        .profile(profile_ref)
        .expect("installed package must create a real profile");

    assert_eq!(profile.id(), profile_ref.profile_id());
    assert_eq!(Some(profile.version()), profile_ref.version());
    assert!(profile.model_binding().is_some(), "fixture package must install model binding");
}

#[test]
fn package_installed_model_binding_is_catalog_resolvable_and_has_local_credential_binding() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world.profile_repository.profile(installed.profile()).unwrap();
    let model_binding = profile.model_binding().expect("model binding exists");

    assert!(
        world
            .model_catalog
            .contains_exact_selection(model_binding.selection()),
        "installed package must register the model selection it puts in the profile"
    );

    assert_eq!(
        profile
            .local_bindings()
            .credential_ref(model_binding.selection().provider_account_id()),
        Some("credential.openai.default"),
        "model provider account must resolve to installed local credential binding"
    );
}

#[test]
fn package_install_rejects_manifest_that_would_create_non_pinnable_profile() {
    let world = AgentOsTestWorld::new();
    let mut manifest = local_ios_agent_runtime::agent_package::AgentPackageManifest::fixture_valid();
    manifest.model.as_mut().unwrap().model_id.clear();

    let error = world
        .package_installer()
        .install(
            manifest,
            local_ios_agent_runtime::agent_package::LocalBindings::empty().with_credential_ref(
                "model.account",
                "credential.openai.default",
                "sha256:local-binding",
            ),
        )
        .expect_err("blank model id must fail before profile persistence");

    assert!(
        error.code().contains("package") || error.code().contains("model"),
        "unexpected error: {error:?}"
    );
}
```

If current fields are private, use the manifest builder API instead of making fields public for the test. If no builder exists, add a production validation helper to the package domain rather than mutating through a test-only bypass.

- [ ] **Step 2: Add AgentProfile readiness contract tests**

Create `local-ios-agent/rust-core/tests/contract/agent_profile_contract.rs` with concrete tests that go through `AgentProfilePublisher` or the current application service entry point. The file must not instantiate final `AgentProfile` directly.

Required tests:

- `profile_publish_rejects_missing_required_slots`: build a draft against `AgentTemplate::assistant_default()`, omit persona/model bindings, publish, and assert failure before any profile is persisted.
- `profile_publish_rejects_duplicate_component_slot_bindings`: publish two persona components through `ComponentCatalogService`, bind the same `AgentSlotId` twice, publish, and assert duplicate-slot failure.
- `profile_publish_rejects_unknown_component_version`: bind a non-existent `UserComponentVersionId`, publish, and assert the component catalog lookup rejects it.
- `profile_publish_rejects_model_selection_not_present_in_catalog`: create a syntactically pinnable `ModelSelection` that is absent from `InMemoryModelBindingCatalog`, publish, and assert rejection before persistence.

Each test must also assert the profile repository remains unchanged after failure.

- [ ] **Step 3: Add Tool -> Security contract tests**

Create `local-ios-agent/rust-core/tests/contract/tool_security_contract.rs`.

Required behavior tests:

- `http_tool_route_uses_injected_security_manager_not_recipe_local_policy`: build an HTTP `ToolRecipe` whose recipe policy allowlists a destination, inject a `SecurityManager` whose permission service denies that destination, route through `ToolRouter`, and assert routing fails with no `ToolExecutionRequest`.
- `http_tool_route_returns_authorized_request_with_bound_egress_metadata`: build an HTTP `ToolRecipe` that requires egress approval, approve it through `SecurityManager`, route through `ToolRouter`, and assert the returned request's compiled recipe, egress decision, and approval grant all refer to the same endpoint origin and operation.

Also add this architecture guard:

```rust
#[test]
fn authorized_tool_request_cannot_be_mutated_after_router_authorizes_it() {
    let source = include_str!("../../src/tool/execution_request.rs");

    assert!(
        !source.contains("pub compiled_recipe:"),
        "ToolExecutionRequest must not expose mutable compiled_recipe field"
    );
    assert!(
        !source.contains("pub egress_decision:"),
        "ToolExecutionRequest must not expose mutable egress_decision field"
    );
    assert!(
        !source.contains("pub approval_grant:"),
        "ToolExecutionRequest must not expose mutable approval_grant field"
    );
}
```

This guard stays until Rust visibility and type names make the authorized envelope impossible to mutate from downstream code.

- [ ] **Step 4: Add Model -> Security -> Inference contract tests**

Create `local-ios-agent/rust-core/tests/contract/model_inference_security_contract.rs`.

Required tests:

- `remote_model_validation_rejects_list_models_decision`: evaluate egress for `remote.provider.list_models`, use that decision in `ProviderAccountValidationRequest::remote`, and assert model validation rejects the mismatched operation decision.
- `remote_inference_rejects_provider_validation_decision`: evaluate egress for `remote.provider.validate_account`, use that decision in `ResolvedModelBinding::remote` or `GenerationRequest`, and assert `InferenceRouter` rejects it before backend `start_session`.
- `local_provider_and_local_inference_do_not_fabricate_egress_decisions`: use local provider account and local model format, assert validation/listing/session paths expose no `DataEgressDecision`, and assert local failures are not reported as egress failures.

These tests intentionally overlap Plan05 and Plan06 because their purpose is to lock the protocol between slices, not individual modules.

- [ ] **Step 5: Strengthen storage transaction contract tests**

Extend `local-ios-agent/rust-core/tests/contract/storage_transaction.rs` with:

- `component_publish_profile_publish_and_package_install_use_unit_of_work_boundaries`: exercise component publish, profile publish, and package install through public service APIs, then assert their writes are staged through `UnitOfWork` and no post-transaction `store.apply()` path remains outside the transaction boundary.
- `archive_event_and_checkpoint_writes_commit_or_abort_together`: use a failure-injecting pending write implementation inside the test module, stage archive, event, and store writes in one `UnitOfWork`, trigger failure, and assert all stores remain unchanged.

Do not add a production `TransactionOutcome` enum.

- [ ] **Step 6: Verify production contract layer**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test contract package_install_creates_profile_that_is_version_pinned_and_repository_resolvable
cargo test --test contract package_installed_model_binding_is_catalog_resolvable_and_has_local_credential_binding
cargo test --test contract profile_publish_rejects_missing_required_slots
cargo test --test contract http_tool_route_uses_injected_security_manager_not_recipe_local_policy
cargo test --test contract remote_model_validation_rejects_list_models_decision
cargo test --test contract archive_event_and_checkpoint_writes_commit_or_abort_together
cargo test --test contract
```

Expected: all pass. If any test exposes a real production contract gap, fix the production code in the same task before moving on.

- [ ] **Step 7: Commit production contract tests**

Run:

```bash
git add local-ios-agent/rust-core/tests/contract.rs local-ios-agent/rust-core/tests/contract local-ios-agent/rust-core/tests/support
git commit -m "test(agent-os): add production contract gates"
```

---

### Task 3: Add Golden Fixtures And Stable Output Tests

**Files:**
- Create: `local-ios-agent/rust-core/tests/golden/agent_package_export.rs`
- Create: `local-ios-agent/rust-core/tests/golden/dto_unknown.rs`
- Create: `local-ios-agent/rust-core/tests/golden/lifecycle_debug_artifacts.rs`
- Create: `local-ios-agent/rust-core/tests/golden/user_component_dto.rs`
- Create: `local-ios-agent/rust-core/tests/fixtures/golden/agent_package_export/agent.yaml`
- Create: `local-ios-agent/rust-core/tests/fixtures/golden/agent_package_export/model.yaml`
- Create: `local-ios-agent/rust-core/tests/fixtures/golden/lifecycle/package_install_preview.json`
- Create: `local-ios-agent/rust-core/tests/fixtures/golden/lifecycle/profile_summary.json`

- [ ] **Step 1: Add package export golden fixture**

Create `local-ios-agent/rust-core/tests/fixtures/golden/agent_package_export/agent.yaml`:

```yaml
schema_version: 1
package_id: agent.fixture
name: Fixture Agent
model_file: model.yaml
package_hash: sha256:fixture
```

Create `local-ios-agent/rust-core/tests/fixtures/golden/agent_package_export/model.yaml`:

```yaml
provider_id: provider.openai_compatible
model_id: gpt-fixture
```

- [ ] **Step 2: Write failing golden test for package export**

Create `local-ios-agent/rust-core/tests/golden/agent_package_export.rs`:

```rust
use local_ios_agent_runtime::agent_package::{AgentPackageExporter, AgentPackageLock};

#[test]
fn agent_package_export_matches_golden_files() {
    let lock = AgentPackageLock::fixture_installed_profile();
    let exported = AgentPackageExporter::default().export(&lock).unwrap();

    assert_eq!(
        exported.files.get("agent.yaml").map(String::as_str),
        Some(include_str!("../fixtures/golden/agent_package_export/agent.yaml"))
    );
    assert_eq!(
        exported.files.get("model.yaml").map(String::as_str),
        Some(include_str!("../fixtures/golden/agent_package_export/model.yaml"))
    );
}
```

- [ ] **Step 3: Add DTO unknown golden regression test**

Create `local-ios-agent/rust-core/tests/golden/dto_unknown.rs`:

```rust
use local_ios_agent_runtime::protocol::ProviderKindDTO;
use local_ios_agent_runtime::user_customization::ComponentKindDTO;

#[test]
fn component_kind_unknown_fixture_stays_decode_safe() {
    let raw = include_str!("../fixtures/user_component/unknown_component_kind.json");
    let decoded = serde_json::from_str::<ComponentKindDTO>(raw).unwrap();

    assert!(matches!(decoded, ComponentKindDTO::Unknown(_)));
}

#[test]
fn provider_kind_unknown_fixture_stays_decode_safe() {
    let decoded = serde_json::from_str::<ProviderKindDTO>(r#""future_provider""#).unwrap();

    assert!(matches!(decoded, ProviderKindDTO::Unknown(value) if value == "future_provider"));
}
```

- [ ] **Step 4: Add user component DTO golden regression test**

Create `local-ios-agent/rust-core/tests/golden/user_component_dto.rs`:

```rust
use local_ios_agent_runtime::user_customization::ComponentContent;

#[test]
fn component_content_fixture_stays_stable_json() {
    let raw = include_str!("../fixtures/user_component/component_content_v1.json");
    let decoded: Vec<serde_json::Value> = serde_json::from_str(raw).unwrap();

    assert!(decoded.iter().any(|value| value["kind"] == "persona"));
    assert!(decoded.iter().any(|value| value["kind"] == "prompt"));
}

#[test]
fn component_content_round_trip_does_not_drop_kind() {
    let persona = ComponentContent::persona("Research persona");
    let value = serde_json::to_value(&persona).unwrap();

    assert_eq!(value["kind"], "persona");
}
```

- [ ] **Step 5: Add lifecycle debug artifact golden tests**

Create `local-ios-agent/rust-core/tests/fixtures/golden/lifecycle/package_install_preview.json` from the canonical JSON returned by package install preview. The fixture must include the package record, profile write, lock write, model binding catalog write, required local binding keys, and event names.

Create `local-ios-agent/rust-core/tests/fixtures/golden/lifecycle/profile_summary.json` from the canonical redacted debug JSON for an installed fixture profile. The fixture must include profile id, pinned profile version, template id, component binding slots, model binding id, model catalog version, and redacted local binding references.

Create `local-ios-agent/rust-core/tests/golden/lifecycle_debug_artifacts.rs`:

```rust
use crate::support::agent_os_fixtures::AgentOsTestWorld;
use crate::support::assertions::assert_redacted_debug_output;

#[test]
fn package_install_preview_matches_golden_and_mentions_all_transaction_writes() {
    let world = AgentOsTestWorld::new();
    let preview = world
        .package_installer()
        .preview(local_ios_agent_runtime::agent_package::AgentPackageManifest::fixture_valid())
        .unwrap();
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
    let profile = world.profile_repository.profile(installed.profile()).unwrap();
    let actual = serde_json::to_string_pretty(&profile.debug_summary()).unwrap() + "\n";

    assert_redacted_debug_output(&actual);
    assert_eq!(
        actual,
        include_str!("../fixtures/golden/lifecycle/profile_summary.json")
    );
}
```

Add production read-only DTO methods for this gate:

- `AgentPackageInstaller::preview(...) -> AgentPackageInstallPreviewDTO`, listing every transaction write and required local binding key.
- `AgentProfile::debug_summary() -> AgentProfileDebugSummaryDTO`, returning a redacted, stable, serde-serializable summary.

Do not serialize private domain structs directly.

- [ ] **Step 6: Verify golden layer**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test golden
```

Expected: PASS. If any formatting differs, update the golden fixture only after confirming that the corresponding production serializer is the intended canonical serializer.

- [ ] **Step 7: Commit golden layer**

Run:

```bash
git add local-ios-agent/rust-core/tests/golden.rs local-ios-agent/rust-core/tests/golden local-ios-agent/rust-core/tests/fixtures/golden
git commit -m "test(agent-os): add golden output gates"
```

---

### Task 4: Add Production Lifecycle Integration Tests

**Files:**
- Create: `local-ios-agent/rust-core/tests/integration/agent_lifecycle_profile_to_runtime.rs`
- Create: `local-ios-agent/rust-core/tests/integration/agent_lifecycle_failure_paths.rs`
- Modify: `local-ios-agent/rust-core/tests/integration.rs`

- [ ] **Step 1: Write package -> profile -> readiness integration test**

Create `local-ios-agent/rust-core/tests/integration/agent_lifecycle_profile_to_runtime.rs`:

```rust
use crate::support::agent_os_fixtures::AgentOsTestWorld;

#[test]
fn package_install_profile_binding_readiness_path_is_runtime_ready() {
    let world = AgentOsTestWorld::new();
    let installed = world.install_fixture_package();
    let profile = world.profile_repository.profile(installed.profile()).unwrap();
    let model_binding = profile.model_binding().unwrap();

    assert_eq!(profile.id().as_str(), "profile:agent.fixture");
    assert!(profile.readiness().is_ready(), "installed profile must be ready before Runtime");
    assert!(world.model_catalog.contains_exact_selection(model_binding.selection()));
    assert_eq!(
        profile
            .local_bindings()
            .credential_ref(model_binding.selection().provider_account_id()),
        Some("credential.openai.default")
    );
}
```

Add production read-only `AgentProfile::readiness()` if the current readiness service is not yet reachable from integration tests. The readiness DTO must report required slot, component version, model binding, credential binding, and permission issues separately.

- [ ] **Step 2: Write lifecycle failure path integration tests**

Create `local-ios-agent/rust-core/tests/integration/agent_lifecycle_failure_paths.rs` with these tests:

- `lifecycle_fails_before_runtime_when_model_credential_binding_is_missing`: install or publish a profile without `model.account`, then assert readiness reports a credential/local-binding issue and Runtime is not invoked.
- `lifecycle_fails_before_runtime_when_remote_model_egress_is_denied`: configure `SecurityManager` to deny the provider endpoint, attempt model readiness/resolution, and assert a permission issue.
- `lifecycle_fails_before_runtime_when_required_persona_component_missing`: publish a profile against the default assistant template without persona, and assert the failure is a builder/profile readiness issue.
- `lifecycle_fails_before_runtime_when_model_catalog_version_is_stale`: publish a profile with a model selection whose catalog version is no longer current, and assert stale-version failure.
- `lifecycle_fails_before_runtime_when_slot_binding_is_ambiguous`: bind the same slot twice and assert duplicate-slot failure.

Each failure-path test must assert:

- No run state is created.
- No runtime execution event is appended.
- The returned error/readiness issue identifies the failing layer (`profile`, `model`, `security`, or `binding`).

- [ ] **Step 3: Verify RED if harness modules are missing**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test integration package_install_profile_binding_readiness_path_is_runtime_ready
```

Expected: FAIL if `integration.rs` does not include the new lifecycle modules.

- [ ] **Step 4: Add modules to integration harness**

Ensure `local-ios-agent/rust-core/tests/integration.rs` includes:

```rust
mod agent_lifecycle_failure_paths;
mod agent_lifecycle_profile_to_runtime;
```

- [ ] **Step 5: Verify integration layer**

Run:

```bash
cd local-ios-agent/rust-core
cargo test --test integration package_install_profile_binding_readiness_path_is_runtime_ready
cargo test --test integration lifecycle_fails_before_runtime_when_model_credential_binding_is_missing
cargo test --test integration
```

Expected: both commands PASS.

- [ ] **Step 6: Commit lifecycle integration tests**

Run:

```bash
git add local-ios-agent/rust-core/tests/integration.rs local-ios-agent/rust-core/tests/integration/agent_lifecycle_profile_to_runtime.rs local-ios-agent/rust-core/tests/integration/agent_lifecycle_failure_paths.rs
git commit -m "test(agent-os): add lifecycle integration gates"
```

---

### Task 5: Add CI Scripts

**Files:**
- Create: `scripts/ci/rust-unit.sh`
- Create: `scripts/ci/rust-contract.sh`
- Create: `scripts/ci/rust-golden.sh`
- Create: `scripts/ci/rust-lint.sh`
- Create: `scripts/ci/rust-integration.sh`
- Create: `scripts/ci/swift-bridge.sh`
- Create: `scripts/ci/agent-os-all.sh`

- [ ] **Step 1: Add Rust unit script**

Create `scripts/ci/rust-unit.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test unit
```

- [ ] **Step 2: Add Rust contract script**

Create `scripts/ci/rust-contract.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test contract
cargo test --test contract --features builtin-openai-compatible compiled_list_includes_openai_provider_when_feature_is_enabled
```

- [ ] **Step 3: Add Rust golden script**

Create `scripts/ci/rust-golden.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test golden
```

- [ ] **Step 4: Add Rust lint script**

Create `scripts/ci/rust-lint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo fmt --check
cargo clippy --all-targets --no-default-features -- -A clippy::never_loop
cargo test --test lint
```

- [ ] **Step 5: Add Rust integration script**

Create `scripts/ci/rust-integration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test integration
```

- [ ] **Step 6: Add Swift bridge script**

Create `scripts/ci/swift-bridge.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CI_HOME="$ROOT/.ci-home"
CLANG_CACHE="$ROOT/local-ios-agent/toolkit/.build/clang-module-cache"

cd "$ROOT/local-ios-agent/rust-core"
cargo build

mkdir -p "$CI_HOME" "$CLANG_CACHE"

cd "$ROOT/local-ios-agent/toolkit"
HOME="$CI_HOME" CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift test --disable-sandbox --scratch-path .build/ci
```

- [ ] **Step 7: Add local all-gates script**

Create `scripts/ci/agent-os-all.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
"$ROOT/scripts/ci/rust-unit.sh"
"$ROOT/scripts/ci/rust-lint.sh"
"$ROOT/scripts/ci/rust-contract.sh"
"$ROOT/scripts/ci/rust-golden.sh"
"$ROOT/scripts/ci/rust-integration.sh"
"$ROOT/scripts/ci/swift-bridge.sh"
```

- [ ] **Step 8: Make scripts executable**

Run:

```bash
chmod +x scripts/ci/rust-unit.sh \
  scripts/ci/rust-contract.sh \
  scripts/ci/rust-golden.sh \
  scripts/ci/rust-lint.sh \
  scripts/ci/rust-integration.sh \
  scripts/ci/swift-bridge.sh \
  scripts/ci/agent-os-all.sh
```

- [ ] **Step 9: Verify scripts**

Run:

```bash
scripts/ci/rust-unit.sh
scripts/ci/rust-contract.sh
scripts/ci/rust-golden.sh
scripts/ci/rust-lint.sh
scripts/ci/rust-integration.sh
scripts/ci/swift-bridge.sh
```

Expected: all PASS.

- [ ] **Step 10: Commit scripts**

Run:

```bash
git add scripts/ci
git commit -m "ci(agent-os): add local test gate scripts"
```

---

### Task 6: Add GitHub Actions CI Gates

**Files:**
- Create: `.github/workflows/agent-os-ci.yml`

- [ ] **Step 1: Create GitHub Actions workflow**

Create `.github/workflows/agent-os-ci.yml`:

```yaml
name: Agent OS CI

on:
  pull_request:
    paths:
      - "local-ios-agent/**"
      - "scripts/ci/**"
      - ".github/workflows/agent-os-ci.yml"
  push:
    branches:
      - master
    paths:
      - "local-ios-agent/**"
      - "scripts/ci/**"
      - ".github/workflows/agent-os-ci.yml"

concurrency:
  group: agent-os-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  rust-lint:
    name: Rust lint and architecture gates
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Rust stable
        run: |
          rustup toolchain install stable --profile minimal
          rustup default stable
          rustup component add clippy rustfmt
      - name: Run rust lint gates
        run: scripts/ci/rust-lint.sh

  rust-unit:
    name: Rust unit tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Rust stable
        run: |
          rustup toolchain install stable --profile minimal
          rustup default stable
      - name: Run unit tests
        run: scripts/ci/rust-unit.sh

  rust-contract:
    name: Rust contract tests
    runs-on: ubuntu-latest
    needs:
      - rust-unit
      - rust-lint
    steps:
      - uses: actions/checkout@v4
      - name: Install Rust stable
        run: |
          rustup toolchain install stable --profile minimal
          rustup default stable
      - name: Run contract tests
        run: scripts/ci/rust-contract.sh

  rust-golden:
    name: Rust golden fixtures
    runs-on: ubuntu-latest
    needs:
      - rust-unit
      - rust-lint
    steps:
      - uses: actions/checkout@v4
      - name: Install Rust stable
        run: |
          rustup toolchain install stable --profile minimal
          rustup default stable
      - name: Run golden tests
        run: scripts/ci/rust-golden.sh

  rust-integration:
    name: Rust integration tests
    runs-on: ubuntu-latest
    needs:
      - rust-contract
      - rust-golden
    steps:
      - uses: actions/checkout@v4
      - name: Install Rust stable
        run: |
          rustup toolchain install stable --profile minimal
          rustup default stable
      - name: Run integration tests
        run: scripts/ci/rust-integration.sh

  swift-bridge:
    name: Swift bridge tests
    runs-on: macos-latest
    needs:
      - rust-contract
    steps:
      - uses: actions/checkout@v4
      - name: Install Rust stable
        run: |
          rustup toolchain install stable --profile minimal
          rustup default stable
      - name: Run Swift bridge tests
        run: scripts/ci/swift-bridge.sh
```

- [ ] **Step 2: Validate workflow syntax locally**

Run:

```bash
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/agent-os-ci.yml"); puts "workflow yaml ok"'
```

Expected: prints `workflow yaml ok`.

- [ ] **Step 3: Verify local gates**

Run:

```bash
scripts/ci/agent-os-all.sh
```

Expected: PASS, including the Swift bridge gate on macOS.

- [ ] **Step 4: Commit workflow**

Run:

```bash
git add .github/workflows/agent-os-ci.yml
git commit -m "ci(agent-os): gate layered tests"
```

---

### Task 7: Add Test Architecture Documentation

**Files:**
- Create: `local-ios-agent/docs/testing/agent-os-test-architecture.md`

- [ ] **Step 1: Write test architecture doc**

Create `local-ios-agent/docs/testing/agent-os-test-architecture.md`:

```markdown
# Agent OS Test Architecture

Agent OS tests are grouped by responsibility, not by implementation convenience.

## Layers

| Layer | Path | CI command | Purpose |
| --- | --- | --- | --- |
| Unit | `local-ios-agent/rust-core/tests/unit/` | `scripts/ci/rust-unit.sh` | One module or local data structure. No cross-slice lifecycle assumptions. |
| Contract | `local-ios-agent/rust-core/tests/contract/` | `scripts/ci/rust-contract.sh` | Boundary behavior between slices: protocol DTOs, storage transactions, package/profile/model contracts, security approvals. |
| Integration | `local-ios-agent/rust-core/tests/integration/` | `scripts/ci/rust-integration.sh` | Multi-step lifecycle flows through several services. |
| Golden | `local-ios-agent/rust-core/tests/golden/` | `scripts/ci/rust-golden.sh` | Stable package/DTO/archive/event output fixtures. Fixture changes are review-worthy API changes. |
| Lint | `local-ios-agent/rust-core/tests/lint/` | `scripts/ci/rust-lint.sh` | Architecture rules and test taxonomy enforcement. |

## Rules For New Agent OS Work

1. Every new slice must add at least one contract test for its public boundary.
2. Every cross-slice lifecycle change must add or update an integration test.
3. Every persisted/exported/debuggable artifact must have a golden fixture before downstream code depends on it.
4. Runtime must not depend on builder/package/profile repositories directly; lint tests own that rule.
5. Top-level Rust test files are reserved for Cargo harnesses: `unit.rs`, `contract.rs`, `integration.rs`, `golden.rs`, `lint.rs`.

## Running Locally

```bash
scripts/ci/rust-lint.sh
scripts/ci/rust-unit.sh
scripts/ci/rust-contract.sh
scripts/ci/rust-golden.sh
scripts/ci/rust-integration.sh
scripts/ci/swift-bridge.sh
```

Before merging Plan03b or Run Snapshot work, run:

```bash
scripts/ci/agent-os-all.sh
scripts/ci/swift-bridge.sh
```
```

- [ ] **Step 2: Commit docs**

Run:

```bash
git add local-ios-agent/docs/testing/agent-os-test-architecture.md
git commit -m "docs(agent-os): document test architecture"
```

---

### Task 8: Final Verification And Merge Gate

**Files:**
- No new files.

- [ ] **Step 1: Run all local gates**

Run:

```bash
scripts/ci/agent-os-all.sh
```

Expected: PASS.

- [ ] **Step 2: Run Swift bridge gate on macOS if checking it independently**

Run:

```bash
scripts/ci/swift-bridge.sh
```

Expected: PASS.

- [ ] **Step 3: Confirm root-level Rust test taxonomy**

Run:

```bash
cd local-ios-agent/rust-core
find tests -maxdepth 1 -type f -name '*.rs' | sort
```

Expected output:

```text
tests/contract.rs
tests/golden.rs
tests/integration.rs
tests/lint.rs
tests/unit.rs
```

- [ ] **Step 4: Confirm Git status**

Run:

```bash
git status --short
```

Expected: clean except pre-existing untracked docs/audits/pi files that are not part of this plan.

- [ ] **Step 5: Commit final cleanup if needed**

If verification required path fixes or docs corrections, run:

```bash
git add local-ios-agent/rust-core/tests scripts/ci .github/workflows local-ios-agent/docs/testing
git commit -m "test(agent-os): finalize layered CI gates"
```

---

## Self-Review

**Spec coverage:** The plan covers unit/contract/integration/golden/lint taxonomy, CI run order and merge gates, production lifecycle gates, architecture linting, Swift bridge checks, and documentation for future plan authors.

**Placeholder scan:** No task uses TBD/TODO/fill-in language. DTO examples use the concrete types present in the current codebase: `ComponentKindDTO` and `ProviderKindDTO`.

**Type consistency:** Rust test target names are `unit`, `contract`, `integration`, `golden`, `lint`; scripts and GitHub Actions use the same names. Cargo module layout uses top-level harness files because nested files are not auto-discovered by Cargo.
