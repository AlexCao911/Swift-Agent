# Rust Core

`rust-core` is the provider-neutral Agent OS kernel for the iOS app. It owns
portable packages and profiles, security gates, context assembly, execution
planning, durable run state, tool policy, and the JSON/C ABI consumed by Swift.

Swift owns all LLM product state and runtime configuration, including local and
cloud target selection, Provider Profiles, credentials, model installations,
and host sessions. C++ owns only on-device inference. Rust does not link an
inference engine or interpret provider/model details.

## Run Boundary

The production LLM run path is:

```text
Swift start request
  -> Rust authoritative preview + global run lease
  -> Swift prepares one exact local/cloud host session
  -> Rust commits a provider-neutral V2 snapshot + host command outbox
  -> Swift streams normalized host events
  -> Rust executes tool policy and commits the final Agent output
```

Durable commands, receipts, event sequences, watchdogs, cancellation, and
restart recovery cross the host boundary without exposing Provider Profile,
API key, Base URL, model path, or engine state to Rust.

## Modules

- `agent_package`: portable V2 package read, validation, install, and export.
- `user_customization`: components, V2 Agent Profiles, templates, and builder graph.
- `prompt` / `context`: prompt compilation, context graph, model input, and archives.
- `tool` / `memory`: tool policy, recipes/results, and memory contributions.
- `security`: permissions, approvals, egress policy, and audit contracts.
- `run_snapshot`: authoritative preview and provider-neutral immutable snapshots.
- `execution`: host worker, tool turns, cancellation, completion, and recovery.
- `storage`: the unified transactional runtime state and durable outboxes.
- `ffi_bridge`: the provider-neutral JSON/C ABI used by Swift.
- `migration`: the narrow read-only legacy Profile translator used during direct
  old-version upgrades.

## Testing

Tests are split by intent:

```text
tests/unit.rs         module behavior
tests/contract.rs     cross-module contracts
tests/integration.rs  lifecycle and bridge flows
tests/golden.rs       stable debug/schema fixtures
tests/lint.rs         architecture boundaries
```

Run the local Agent OS gate from the repo root:

```bash
scripts/ci/agent-os-all.sh
```

For Rust-only work:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
```

The deterministic complete Swift LLM gate is:

```bash
LOCAL_AGENT_PHASE5_IPHONE_UDID="<iPhone Simulator UDID>" \
LOCAL_AGENT_PHASE5_IPAD_UDID="<iPad Simulator UDID>" \
  scripts/run-llm-phase-5-contracts.sh
```
