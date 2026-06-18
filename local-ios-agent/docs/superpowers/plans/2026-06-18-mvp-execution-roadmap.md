# Local iOS Agent MVP Execution Roadmap

Date: 2026-06-18
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## Purpose

This roadmap is the execution spine for the Local iOS Agent MVP after the Rust
core runtime foundation. Plans 1-7 establish the runtime semantics. Plans 8-12
connect that runtime to Swift native capability execution, local model provider
selection, C++ inference boundaries, and the SwiftUI MVP shell.

The architectural boundary remains:

```text
C++ / Metal / llama.cpp = inference backend boundary
Rust Core Runtime      = agent loop, state, context, tools, policy, events
Swift Native Toolkit   = iOS APIs, permissions, App Intents, Shortcuts bridge
SwiftUI Frontend       = presentation and interaction
```

## Current Baseline

Implemented in `rust-core`:

- Runtime IDs, error categories, runtime events, run states, cancellation, and
  replay of waiting tool runs.
- `SessionTree`, `SessionCursor`, in-memory event store, and SQLite event store
  with closure-table active branch reconstruction.
- `ContextController`, prompt layering, budget logic, compaction events,
  retention filtering, and `PromptDebugSnapshot`.
- `TokenizerAdapter`, `MockTokenizer`, `ModelProvider`, and
  `MockStreamingProvider`.
- `StreamBatcher`.
- `ToolSchema`, `ToolCall`, `ToolResult`, `ToolRegistry`, `ToolRouter`,
  `ToolExecutionRequest`, parser validation, and Swift execution routing.
- `PolicyEngine`, permission state modeling, approval queue, audit policy,
  `SecurityManager`, and Rust-Swift approval protocol DTOs.

Not implemented yet:

- Runtime bridge callable from Swift.
- Swift package / iOS app structure.
- Swift native toolkit executor and first native/meta tools.
- Provider registry, provider profile selection, and Desktop MiniCPM HTTP
  provider.
- C++ / llama.cpp on-device inference boundary.
- SwiftUI chat shell, provider settings, approval UI, tool/audit rows, and
  prompt debug view.

## Plan Authoring Rule

Every detailed plan must start by checking the current code. The plan must
include a `Current Code Audit` section that states what exists, what is missing,
and which gaps are assigned to that plan.

## Branch Strategy

Planning documents may be written on `master`. Implementation must happen in
isolated worktrees:

```text
native-toolkit branch:
  Plan 8: Swift Runtime Bridge Foundation
  Plan 9: Swift Native Toolkit + Basic Meta Tools

ai-model branch:
  Plan 10: Desktop MiniCPM Provider + Provider Selection
  Plan 11: C++ On-Device Provider Boundary

frontend branch:
  Plan 12: SwiftUI MVP Shell + Acceptance Hardening
```

The branches are intentionally split by ownership. Plan 12 consumes the bridge,
toolkit, and provider contracts after they are merged or rebased into the
frontend branch.

## Execution Phases

### Plan 1: Rust Runtime Mock Provider Foundation

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-17-plan-01-rust-runtime-mock-provider.md`

### Plan 2: SQLite Memory Store

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-17-plan-02-sqlite-memory-store.md`

### Plan 3: Core Agent Loop + Run State Machine

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-03-core-agent-loop-run-state.md`

### Plan 4: Tool Orchestration

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-04-tool-orchestration.md`

### Plan 5: Context Controller

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-05-context-controller.md`

### Plan 6: Memory Foundation

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-06-memory-foundation.md`

### Plan 7: Security Manager

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-07-security-manager.md`

### Plan 8: Swift Runtime Bridge

Status: planned.

Implementation branch:
`codex/local-ios-agent-native-toolkit`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-08-swift-runtime-bridge.md`

Owns:

- `ios-app` Swift package skeleton for bridge targets.
- Swift DTOs matching Rust runtime events, turn results, tool schemas, tool
  execution requests, approval requests, approval responses, tool results,
  session IDs, and prompt debug snapshots.
- `RuntimeClient`, `MockRuntimeClient`, and `RustRuntimeClient`.
- C ABI or UniFFI-ready bridge functions for the existing Rust runtime.
- Generic tool schema registration as a bridge capability, without defining
  native tools.

Does not own:

- native tool implementations;
- provider implementations;
- SwiftUI view orchestration.

### Plan 9: Swift Native Toolkit

Status: planned.

Implementation branch:
`codex/local-ios-agent-native-toolkit`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-09-swift-native-toolkit.md`

Owns:

- Native tool protocol and catalog.
- Native tool schema export into bridge DTOs.
- Basic meta tools: list registered tools and report permission status.
- First read tool: calendar event search through an injectable calendar facade.
- First confirmation-required write tool: reminder creation through an
  injectable reminders facade.
- Shortcuts read boundary for voice shortcut listing.
- Native executor that converts `ToolExecutionRequestDTO` into `ToolResultDTO`,
  without submitting results to Rust itself.

Does not own:

- app startup registration into Rust;
- pending-tool drain loops;
- approval sheet UI.

### Plan 10: LLM Provider Layer

Status: planned.

Implementation branch:
`codex/local-ios-agent-ai-model`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-10-desktop-minicpm-provider.md`

Owns:

- Provider profile/config types and provider registry.
- Runtime provider selection, because provider choice must update provider and
  tokenizer state in Rust.
- Provider-generation cancellation, because runtime cancel must be able to
  signal real model generation.
- Desktop MiniCPM provider using an OpenAI-compatible local HTTP endpoint.
- Chat completion request/response adapter for text-first MVP.
- Provider-tokenizer alignment and tokenizer-aware budget fitting.
- `CancellationToken`-based provider cancellation.
- Provider settings persistence through `EventStore`.
- Active-run rejection for provider switching.
- Runtime prompt debug snapshot capture around provider calls.
- Local endpoint runbook and smoke test strategy.

Does not own:

- C++/Metal inference internals;
- provider picker UI.

### Plan 11: C++ Inference Backend Boundary

Status: planned.

Implementation branch:
`codex/local-ios-agent-ai-model`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-11-cpp-ondevice-provider-boundary.md`

Owns:

- `inference` directory with a narrow C ABI header.
- Mock C++ backend implementing load, stream, cancel, and release semantics.
- Opaque stream-handle C ABI so backend cancel targets a specific stream.
- Rust backend adapter and `OnDeviceMiniCPMProvider` behind the Plan 10 provider
  abstraction.
- Resource lifecycle and cancellation tests.
- C ABI-backed smoke coverage, not only Rust mock backend tests.
- Notes for future GGUF/Metal integration without mixing inference concerns into
  Rust runtime state.

Does not own:

- provider registry design;
- Swift bridge internals;
- SwiftUI.

### Plan 12: SwiftUI Frontend MVP

Status: planned.

Implementation branch:
`codex/local-ios-agent-frontend`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-12-swiftui-mvp-shell.md`

Owns:

- App bootstrap/composition across Plans 8-10.
- SwiftUI chat shell.
- Provider selector and endpoint settings.
- Approval sheet.
- Tool/audit rows.
- Prompt debug view.
- View model integration with runtime client and native toolkit executor,
  including run-filtered and loop-guarded pending-tool drain.
- Provider selector that depends on the Plan 10 provider-control capability.
- MVP acceptance checklist and developer runbook.

Does not own:

- runtime bridge internals;
- native tool definitions;
- LLM or C++ provider implementations.
- temporary SwiftUI-only substitutes for missing lower-layer contracts.

## Development Rules

- Use TDD for every runtime, Swift toolkit, provider, and view-model behavior.
- Commit after each completed task.
- Stage explicit paths only; never stage `pi/`.
- Planning documents may live on `master`; implementation work must use the
  branch strategy above.
- Rust orchestrates; Swift executes iOS APIs.
- C++ exposes only inference operations.
- SwiftUI renders state; it must not become the source of truth for sessions,
  tools, memory, or provider state.
