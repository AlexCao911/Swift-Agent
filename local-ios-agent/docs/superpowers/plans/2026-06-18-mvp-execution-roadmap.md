# Local iOS Agent MVP Execution Roadmap

Date: 2026-06-18
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## Purpose

This roadmap splits the remaining MVP into small execution plans that can be
implemented, tested, and committed one at a time. It is based on the current
repository state after Plan 1 and Plan 2.

Current audit companion:
`local-ios-agent/docs/superpowers/plans/2026-06-18-current-code-audit-and-gap-review.md`

The architectural boundary remains:

```text
C++ / Metal / llama.cpp = future inference backend
Rust Core Runtime      = agent loop, state, context, tools, policy, events
Swift Native Toolkit   = iOS APIs, permissions, App Intents, Shortcuts bridge
SwiftUI Frontend       = presentation and interaction
```

## Current Baseline

Implemented:

- Rust crate skeleton under `local-ios-agent/rust-core`.
- Runtime IDs, errors, runtime events, and event kinds.
- Event-sourced `SessionTree`.
- In-memory closure-table event store.
- SQLite `EventStore` with `sessions`, `events`, `event_paths`, and
  `audit_log` tables.
- Active-branch reconstruction through closure-table path rows.
- `ContextController` and `PromptFrame` basics.
- `TokenizerAdapter` and deterministic `MockTokenizer`.
- `MockStreamingProvider`.
- `StreamBatcher`.
- Approval DTOs and `PolicyEngine` stubs.
- Tool DTOs: `ToolSchema`, `ToolCall`, and `ToolResult`.
- Rust tests for runtime, session tree, SQLite store, approvals, context, mock
  provider, and stream batching.

Not implemented:

- Run state machine, cancellation, and replay from persisted events.
- Tool registry, tool router, JSON validation, and executor bridge.
- Full tool-call lifecycle inside `AgentRuntime`.
- Tool-result injection and model continuation after tool execution.
- Runtime use of SQLite as the app persistence backend.
- Provider settings persistence.
- Prompt debug export API.
- Context truncation beyond fail-fast budget checks.
- UniFFI bridge.
- Swift package or iOS app shell.
- Swift Native Toolkit and iOS permission/tool execution.
- Shortcuts / `INVoiceShortcutCenter` bridge.
- Desktop MiniCPM-V-4.6 provider.
- C++ on-device inference boundary.
- End-to-end MVP smoke tests.

## Plan Authoring Gate

Before writing each detailed implementation plan, perform a current-code audit:

1. Read the relevant source files and tests.
2. Run targeted `rg` checks for the capability being planned.
3. Compare requested gaps or external review notes against actual code behavior.
4. Add a "Current Code Audit" section to the detailed plan.
5. Assign each valid gap to the current plan, a later MVP plan, or a post-MVP
   backlog item.

This gate prevents stale plans from assuming code that does not exist, or
dragging post-MVP concerns into the next small execution step.

## Execution Phases

### Plan 1: Rust Runtime Mock Provider Foundation

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-17-rust-runtime-mock-provider.md`

### Plan 2: SQLite Memory Store

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-17-sqlite-memory-store.md`

### Plan 3: Rust Tool Runtime Lifecycle

Status: next.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-rust-tool-runtime-lifecycle.md`

Builds:

- `ToolRegistry`
- `ToolExecutor` trait
- `ToolRouter`
- provider-emitted tool calls
- read-only tool execution
- approval-required suspension event path
- tool result persistence and injection into follow-up model context

Why this is next:

Swift should remain the real iOS tool layer, but Rust first needs a tested
orchestration contract. Without this, the UniFFI bridge would expose unstable
shapes and Swift would be forced to compensate for missing runtime semantics.

### Plan 4: Persistent Runtime and Context Debugging

Status: planned after Plan 3.

Builds:

- Runtime construction with SQLite-backed sessions.
- Session creation and branch continuation that survive runtime recreation.
- Run state model for running, suspended, waiting-tool, failed, cancelled, and
  completed states.
- Run cancellation that appends `RunCancelled` without deleting prior events.
- Replay from persisted events into runtime state after restart.
- Provider settings storage.
- Audit log writes for tool lifecycle.
- Prompt debug snapshots for the last model call.
- Conservative context truncation at message/tool-result boundaries.

Why this follows Plan 3:

Tool results and audit rows must be known before designing the final persistent
runtime schema and prompt debug export.

### Plan 5: UniFFI Runtime Bridge

Status: planned after Plan 4.

Builds:

- UniFFI-compatible DTOs.
- `AgentCoordinator` facade.
- Swift-callable runtime creation.
- Swift-callable `create_session`, `send_message`, `cancel`,
  `register_tool`, `submit_approval_decision`, and `submit_tool_result`.
- Event subscription surface with batched assistant deltas.
- FFI-safe error mapping.
- FFI-safe approval and tool-result submission shape.

Why this follows Plan 4:

The FFI boundary should expose stable runtime semantics, not temporary Rust
internals. SQLite-backed sessions and prompt debug snapshots need to exist
before SwiftUI depends on them.

### Plan 6: SwiftUI Shell With Mock Runtime

Status: planned after Plan 5.

Builds:

- `ios-app` SwiftUI project.
- Chat timeline.
- Session creation and message sending through UniFFI.
- Provider selector with mock provider as the first option.
- Basic branch indicator.
- Debug `PromptFrame` viewer.
- Runtime event rendering smoke tests.

Why this follows Plan 5:

SwiftUI should consume the generated bridge and runtime event stream instead of
inventing a parallel local state model.

### Plan 7: Swift Native Toolkit and Approval Flow

Status: planned after Plan 6.

Builds:

- Swift native tool registry.
- One read tool backed by an iOS framework.
- One confirmation-required write tool.
- Approval sheet.
- LocalAuthentication integration point for confirmation-required tools when
  enabled by policy.
- Permission-state surfacing.
- Structured `ToolResult` return to Rust.
- Shortcuts bridge skeleton for `INVoiceShortcutCenter`.

Why this follows Plan 6:

The UI and bridge must exist before native tools can safely request permissions,
display approvals, and stream tool lifecycle events back to the user.

### Plan 8: Desktop MiniCPM Provider

Status: planned after Plan 7.

Builds:

- Local endpoint configuration.
- Desktop MiniCPM provider adapter for simulator development.
- Streaming HTTP response parsing.
- Provider tokenizer contract with conservative safety margin.
- Real text smoke test against a Mac-local OpenAI-compatible endpoint.
- Optional image payload path when the endpoint supports it.

Why this follows Plan 7:

The runtime, UI, and tool path should be stable before introducing a real model.
This keeps model issues separate from runtime/tooling issues.

### Plan 9: MVP Acceptance Hardening

Status: planned after Plan 8.

Builds:

- End-to-end mock-provider smoke test.
- End-to-end Desktop MiniCPM smoke test.
- Tool lifecycle audit verification.
- Prompt debug verification.
- Cancellation and provider error path tests.
- MVP acceptance checklist against the design spec.
- Post-MVP backlog split for long-term memory, semantic retrieval, SQLCipher,
  and true on-device C++ inference.

Why this is last:

It verifies the full MVP rather than adding a new architectural subsystem.

## Development Rules

- Use TDD for runtime behavior.
- Use small commits after each completed task.
- Stage explicit paths only; never stage `pi/`.
- Keep Swift native tools in Swift; Rust orchestrates and records.
- Keep C++ inference out of the MVP except for the future provider boundary.
- Avoid adding abstractions until a plan needs them for a real test.

## Recommended Execution Mode

Use inline execution with `superpowers:executing-plans` for Plans 3 and 4 because
runtime modules are tightly coupled. Reconsider subagent execution for SwiftUI
or Desktop MiniCPM work once the boundaries become more independent.
