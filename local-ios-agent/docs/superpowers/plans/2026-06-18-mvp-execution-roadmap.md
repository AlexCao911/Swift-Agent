# Local iOS Agent MVP Execution Roadmap

Date: 2026-06-18
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## Purpose

This roadmap replaces the earlier mixed plans with a cleaner sequence. Plan 1
and Plan 2 are already complete. Plans 3-7 build the Rust runtime foundation in
the right order before UniFFI, SwiftUI, Swift native tools, and Desktop MiniCPM
are planned in detail.

The architectural boundary remains:

```text
C++ / Metal / llama.cpp = future inference backend
Rust Core Runtime      = agent loop, state, context, tools, policy, events
Swift Native Toolkit   = iOS APIs, permissions, App Intents, Shortcuts bridge
SwiftUI Frontend       = presentation and interaction
```

## Current Baseline

Implemented:

- Rust crate skeleton.
- Runtime IDs, error categories, runtime events.
- `SessionTree`.
- In-memory event store.
- SQLite event store with closure-table active branch reconstruction.
- Basic `ContextController` and `PromptFrame`.
- `TokenizerAdapter` and `MockTokenizer`.
- `MockStreamingProvider`.
- `StreamBatcher`.
- Approval DTOs and simple `PolicyEngine`.
- Tool DTOs: `ToolSchema`, `ToolCall`, `ToolResult`.

Not implemented:

- Complete multi-step agent loop.
- Run state machine, cancellation, replay, persistent runtime cursors.
- Tool registry/router/parser/execution request/result continuation.
- Full context controller with prompt layering, budget, retention, compaction.
- Long-term memory, memory candidates, branch summaries, blob metadata,
  provider settings, audit storage.
- Security manager with permission scopes, approval queue, approval protocol.
- UniFFI, SwiftUI, Swift native toolkit, Desktop MiniCPM provider.

## Plan Authoring Rule

Every future detailed plan must start by checking the current code. The plan
must include a `Current Code Audit` section that states what exists, what is
missing, and which gaps are assigned to that plan.

## Execution Phases

### Plan 1: Rust Runtime Mock Provider Foundation

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-17-rust-runtime-mock-provider.md`

### Plan 2: SQLite Memory Store

Status: complete.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-17-sqlite-memory-store.md`

### Plan 3: Core Agent Loop + Run State Machine

Status: next.

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-core-agent-loop-run-state.md`

Owns:

- Multi-step agent loop skeleton.
- `running / waiting_tool / suspended / failed / cancelled / completed`.
- Run cancellation.
- Run replay from events.
- Multi-session runtime cursor.
- Tool-call and tool-result continuation slots, without implementing registry
  or Swift execution yet.

### Plan 4: Tool Orchestration

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-tool-orchestration.md`

Owns:

- `ToolRegistry`.
- Tool call JSON parse and validation.
- Policy route into allow, deny, approval, or Swift execution request.
- `ToolExecutionRequest`.
- Swift result submission entry point.
- Recoverable tool errors.

### Plan 5: Context Controller

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-context-controller.md`

Owns:

- Active branch projection.
- System/policy/memory prompt layering.
- Tool schema injection strategy.
- Tool result retention and sensitivity filtering.
- Context budget management.
- Provider tokenizer alignment interface.
- Summary and compaction events.

### Plan 6: Memory Foundation

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-memory-foundation.md`

Owns:

- Long-term memory tables.
- Memory extraction candidates.
- Keyword index.
- Branch summary persistence.
- Blob/image reference strategy.
- Audit and provider settings persistence.

### Plan 7: Security Manager

Plan file:
`local-ios-agent/docs/superpowers/plans/2026-06-18-security-manager.md`

Owns:

- Policy engine.
- Permission scopes.
- Per-tool risk policy.
- Approval pending queue.
- Audit log writing policy.
- Rust-Swift approval protocol.
- LocalAuthentication integration-point protocol.

## After Plan 7

Only after these runtime foundations are stable, write the next plans:

- Plan 8: UniFFI bridge.
- Plan 9: SwiftUI shell.
- Plan 10: Swift Native Toolkit implementation.
- Plan 11: Desktop MiniCPM provider.
- Plan 12: MVP acceptance hardening.

## Development Rules

- Use TDD for every runtime behavior.
- Commit after each completed task.
- Stage explicit paths only; never stage `pi/`.
- Rust orchestrates; Swift executes iOS APIs.
- Keep long-term memory and SQLCipher/Data Protection scoped to memory/security
  plans rather than scattering them across UI work.
