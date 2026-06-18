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

### Plan 8: Swift Runtime Bridge Foundation

Status: planned.

Implementation branch:
`codex/local-ios-agent-native-toolkit`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-08-swift-runtime-bridge.md`

Owns:

- `ios-app` Swift package skeleton.
- Swift DTOs matching Rust runtime events, turn results, tool execution
  requests, approval requests, approval responses, and tool results.
- Swift runtime client protocol plus deterministic mock client.
- Rust C-compatible JSON bridge for mock runtime calls, used as a stable bridge
  until a generated UniFFI layer is introduced.
- Cross-language fixture tests proving Swift DTOs and Rust bridge JSON use the
  same field names.

### Plan 9: Swift Native Toolkit + Basic Meta Tools

Status: planned.

Implementation branch:
`codex/local-ios-agent-native-toolkit`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-09-swift-native-toolkit.md`

Owns:

- Native tool protocol and catalog.
- Basic meta tools: list registered tools and report permission status.
- First read tool: calendar event search through an injectable calendar facade.
- First confirmation-required write tool: reminder creation through an
  injectable reminders facade.
- Shortcuts read boundary for voice shortcut listing.
- Native executor that converts `ToolExecutionRequestDTO` into `ToolResultDTO`.

### Plan 10: Desktop MiniCPM Provider + Provider Selection

Status: planned.

Implementation branch:
`codex/local-ios-agent-ai-model`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-10-desktop-minicpm-provider.md`

Owns:

- Provider profile/config types.
- Provider registry and provider selection.
- Desktop MiniCPM provider using an OpenAI-compatible local HTTP endpoint.
- Chat completion request/response adapter for text-first MVP.
- Conservative tokenizer adapter for Desktop MiniCPM.
- Local endpoint runbook and smoke test strategy.

### Plan 11: C++ On-Device Provider Boundary

Status: planned.

Implementation branch:
`codex/local-ios-agent-ai-model`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-11-cpp-ondevice-provider-boundary.md`

Owns:

- `inference` directory with a narrow C ABI header.
- Mock C++ backend implementing load, stream, cancel, and release semantics.
- Rust on-device provider boundary that depends on a backend trait before real
  llama.cpp linkage.
- Resource lifecycle and cancellation tests.
- Notes for future GGUF/Metal integration without mixing inference concerns into
  Rust runtime state.

### Plan 12: SwiftUI MVP Shell + Acceptance Hardening

Status: planned.

Implementation branch:
`codex/local-ios-agent-frontend`

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-plan-12-swiftui-mvp-shell.md`

Owns:

- SwiftUI chat shell.
- Provider selector and endpoint settings.
- Approval sheet.
- Tool/audit rows.
- Prompt debug view.
- View model integration with runtime client and native toolkit executor.
- MVP acceptance checklist and developer runbook.

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
