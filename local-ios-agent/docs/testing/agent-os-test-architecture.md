# Agent OS Test Architecture

This project uses layered tests so Agent OS modules can grow without silently breaking cross-module contracts.

## Layers

| Layer | Path | Local gate | Purpose |
| --- | --- | --- | --- |
| Unit | `local-ios-agent/rust-core/tests/unit/` | `scripts/ci/rust-unit.sh` | Module-local behavior with minimal collaborators. |
| Contract | `local-ios-agent/rust-core/tests/contract/` | `scripts/ci/rust-contract.sh` | Cross-slice API contracts, security gates, transaction boundaries, and schema compatibility. |
| Golden | `local-ios-agent/rust-core/tests/golden/` | `scripts/ci/rust-golden.sh` | Stable package, DTO, debug, snapshot, archive, and event output. |
| Integration | `local-ios-agent/rust-core/tests/integration/` | `scripts/ci/rust-integration.sh` | Lifecycle paths across package/profile/model/security/runtime-facing boundaries. |
| Lint | `local-ios-agent/rust-core/tests/lint/` | `scripts/ci/rust-lint.sh` | Architecture rules, test taxonomy, formatting, and clippy. |
| Swift Bridge | `local-ios-agent/toolkit/Tests/` | `scripts/ci/swift-bridge.sh` | Rust staticlib/bridge compatibility with Swift-facing DTOs. |

## Rules For New Agent OS Work

1. Every new slice adds or updates at least one contract test.
2. Every cross-slice lifecycle change adds or updates an integration test.
3. Every persisted, exported, or debug-visible artifact gets a golden fixture before another slice depends on it.
4. Runtime must not depend on Agent Builder, package install, profile repository, or component catalog modules.
5. Top-level Rust test files are only Cargo harnesses: `unit.rs`, `contract.rs`, `integration.rs`, `golden.rs`, and `lint.rs`.
6. Shared fixtures live under `tests/support/` and must use production public APIs instead of bypass constructors.
7. Tests that validate security or permission behavior should assert both the allowed path and at least one denied/mismatched path.
8. Transaction tests must verify rollback leaves all participating stores unchanged.

## Current Production Gates

- Package install creates a version-pinned, repository-resolvable profile.
- Package-installed model bindings are resolvable through the model binding catalog.
- Package install rejects secret-like manifests through the full install path and leaves package/profile/model stores unchanged.
- Published profiles reject missing required slots, duplicate component slots, unknown component versions, and unknown model selections.
- HTTP tool routing uses the injected `SecurityManager`; recipe allowlists cannot bypass global egress policy.
- Remote model provider and inference paths reject mismatched egress decisions.
- Local provider and local inference paths do not fabricate data egress decisions.
- Package install preview and installed profile debug summaries have stable redacted golden output.
- SQLite legacy schema fixtures migrate forward without losing runtime history.
- SQLite file-lock behavior is covered by a real file-backed integration test.
- Runtime marks a run failed when provider streaming stops after partial output.
- Swift DTOs decode Rust golden fixtures with unknown provider kinds without crashing.
- `rust-lint.sh` currently gates formatting and architecture lint tests. Clippy runs as advisory because the inherited codebase has pre-existing warnings; tighten it to `-D warnings` after a dedicated clippy cleanup pass.
- `rust-unit.sh` runs unit tests with `--test-threads=1` and isolates the inherited localhost transport socket test. In the Codex network-disabled sandbox, that socket test is skipped by the script; GitHub Actions and normal local shells still run it.

## Hardening Roadmap

The current architecture lint strips comments/strings and checks path-like dependencies so alias imports are caught without comment/string false positives. This is still an interim guard.

The final architecture boundary should be Cargo crate isolation:

- `agent-os-runtime` should not depend on builder/package/profile repository crates.
- `agent-os-builder` should depend on protocol/component/model contracts but not runtime execution.
- `agent-os-package` should depend on protocol/storage/application service contracts but not runtime execution.
- The Swift staticlib crate should compose these crates at the FFI boundary.

Once that split exists, Cargo dependency resolution becomes the primary architecture lint and `tests/lint/architecture_agent_os.rs` can shrink to checking crate manifests and public bridge exports.

## Running Locally

```bash
scripts/ci/rust-unit.sh
scripts/ci/rust-lint.sh
scripts/ci/rust-contract.sh
scripts/ci/rust-golden.sh
scripts/ci/rust-integration.sh
scripts/ci/swift-bridge.sh
```

Run all local gates:

```bash
scripts/ci/agent-os-all.sh
```

## CI Order

GitHub Actions runs:

1. Rust lint and Rust unit in parallel.
2. Rust contract and Rust golden after lint/unit pass.
3. Rust integration after contract/golden pass.
4. Swift bridge on macOS after contract passes.

This order keeps fast module failures close to the top while preventing lifecycle tests from running against a broken protocol foundation.
