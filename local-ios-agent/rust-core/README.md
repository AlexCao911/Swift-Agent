# Rust Core

`rust-core` owns the local Agent OS semantics for the iOS app: package/profile
resolution, security gates, context assembly, execution planning, runtime state,
and the JSON/C ABI consumed by Swift.

Swift owns UI, native iOS tool execution, and presentation state. C++ owns
low-level on-device inference backends. Rust owns the contracts between them.

## Run Boundary

The intended Agent OS run path is:

```text
StartRunRequestDTO
  -> AgentOSApplicationService
  -> RunSnapshotService
  -> ExecutionPlanner
  -> RunMachine
  -> debug archive / runtime events
```

Swift sends only profile id and user intent. Rust captures trusted permission,
credential, local binding, snapshot, and execution state.

## Modules

- `protocol`: shared ids, definitions, registries, plugin and DTO safety shells.
- `agent_package`: portable agent package read/validate/install/export boundary.
- `user_customization`: user components, agent profiles, templates, builder graph.
- `model` / `inference`: provider accounts, model bindings, backend routing.
- `prompt` / `context`: prompt compilation, context graph, model input, archives.
- `tool` / `memory`: tool recipes/results and memory provider contributions.
- `security`: permissions, approvals, credentials, data egress, audit contracts.
- `run_snapshot`: immutable run snapshot resolution from published profile state.
- `execution` / `runtime`: execution plans, effects, checkpoints, run machine.
- `storage`: transaction, event store, archive store, migration contracts.
- `core`: legacy conversation runtime and provider/session infrastructure.
- `ffi_bridge`: JSON/C ABI for Swift bridge clients.
- `app_service`: application-service facade that wires shared repositories/services.

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

## Current Limits

- Some Swift app target tests require a full Xcode developer directory, not only
  Command Line Tools.
- Agent OS debug archives exposed through the current bridge are process-local;
  durable debug archive loading belongs in the storage-backed application service.
- Package/builder/snapshot/permission live Swift clients exist as DTO/protocol
  boundaries first; full shared-repository live facades are the next service layer.
