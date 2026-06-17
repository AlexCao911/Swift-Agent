# Current Code Audit and MVP Gap Review

Date: 2026-06-18
Project path: `/Users/alexandercou/Projects/Alex-agent/local-ios-agent`

## Audit Method

This audit was performed before drafting the next implementation plan. It used
the current repository state, direct file reads, and targeted `rg` checks across
`local-ios-agent/rust-core/src`, `local-ios-agent/rust-core/tests`, and existing
design documents.

Relevant current files:

- `local-ios-agent/rust-core/src/core/runtime.rs`
- `local-ios-agent/rust-core/src/core/provider.rs`
- `local-ios-agent/rust-core/src/context/prompt_frame.rs`
- `local-ios-agent/rust-core/src/context/tokenizer.rs`
- `local-ios-agent/rust-core/src/memory/sqlite.rs`
- `local-ios-agent/rust-core/src/security/approval.rs`
- `local-ios-agent/rust-core/src/security/policy.rs`
- `local-ios-agent/rust-core/src/tool/schema.rs`
- `local-ios-agent/rust-core/src/tool/result.rs`

## Current Reality

Implemented in code:

- `AgentRuntime::create_session`.
- `AgentRuntime::send_message` for one mock provider turn.
- In-memory `SessionTree` with active leaf tracking.
- SQLite event store with closure-table active branch reconstruction.
- `PromptFrame` projection for user messages, assistant completed messages, and
  tool result messages.
- `TokenizerAdapter` with `MockTokenizer`.
- `MockStreamingProvider` that streams text deltas and a completed message.
- `PolicyEngine` with `ReadOnly`, `Confirm`, and `Destructive` decisions.
- `ApprovalRequest`, `ApprovalDecision`, and `SuspendedRun` DTO/lifecycle tests.
- Tool DTOs: `ToolSchema`, `ToolCall`, `ToolResult`.

Not implemented in code:

- Run state machine.
- Run cancellation.
- Runtime replay from SQLite.
- Persistent runtime sessions.
- Tool registry.
- Tool router.
- Tool JSON validation.
- Provider-emitted tool-call events.
- Swift tool execution request boundary.
- Approval pending queue inside `AgentRuntime`.
- Tool result continuation loop.
- Audit log write API.
- Prompt debug export API.
- Context truncation or compaction.
- Blob/image metadata table API.
- Long-term memory extraction.
- UniFFI.
- SwiftUI app.
- Swift Native Toolkit.
- Desktop MiniCPM provider.

## Review of Supplied Gap Report

### 1. Rust Runtime Gaps

Assessment: reasonable.

The current runtime is a one-turn mock loop. It does not yet model:

- `running`
- `waiting_tool`
- `suspended`
- `failed`
- `cancelled`
- `completed`

It also does not support cancellation or replay after process restart. Multi
session support exists only as an in-memory `HashMap<SessionId, SessionTree>`,
not as persistent session listing or restoration.

Planning decision:

- Plan 3 handles the tool-call lifecycle inside the current runtime.
- Plan 4 must add run state, cancellation, persistent sessions, replay, audit
  writes, and prompt debug snapshots before UniFFI.

### 2. Tool Orchestration Gaps

Assessment: reasonable.

Current code has only DTOs. `ToolRegistry`, `ToolRouter`, argument validation,
tool execution request modeling, and Swift result submission are missing.

Planning decision:

- Plan 3 adds `ToolRegistry`, `ToolExecutor`, `ToolRouter`, JSON validation,
  read-only mock execution, denied tool modeling, and suspension for
  confirmation-required tools.
- Plan 5 exposes the tool execution request boundary through UniFFI.
- Plan 7 implements real Swift native tools.

### 3. Context Gaps

Assessment: reasonable.

The current context layer is a useful starting point, but it is not a complete
context controller. It does not yet implement:

- layered system/runtime/memory prompts,
- detailed active-branch projection,
- tool schema selection strategy,
- tool result retention rules,
- context budget truncation,
- summary or compaction generation,
- provider-specific tokenizer alignment beyond the mock adapter.

Planning decision:

- Plan 3 only injects tool results enough to prove model continuation.
- Plan 4 expands context budgeting, prompt debug export, and conservative
  truncation at safe boundaries.
- Desktop MiniCPM tokenizer alignment belongs to Plan 8.

### 4. Memory and Long-Term Memory Gaps

Assessment: partially reasonable, but some items are not MVP blockers.

SQLite currently stores sessions/events/event paths and defines `audit_log`, but
there is no long-term memory pipeline, semantic index, blob API, or encrypted
storage. This is a real gap for the long-term product vision.

For the MVP, long-term memory should remain a reserved boundary until the
runtime, Swift bridge, tool lifecycle, and real model path work end to end.

Planning decision:

- Plan 4 should add audit writes, provider settings, runtime replay, and blob
  reference APIs if needed for prompt/debug flow.
- Long-term memory extraction and semantic retrieval should be a post-MVP plan
  unless the MVP acceptance checklist changes.
- SQLCipher and iOS Data Protection should be handled after the iOS storage
  location and app lifecycle are known.

### 5. Security Gaps

Assessment: reasonable with one boundary correction.

Rust currently has policy DTOs and a simple `PolicyEngine`, but lacks permission
scope modeling, audit writes, approval pending queues, and FFI-safe approval
resumption. Face ID and LocalAuthentication should not be implemented in Rust.
Rust should request approval and track state; Swift should present biometric or
native approval UI.

Planning decision:

- Plan 3 uses risk levels to choose allow, deny, or suspend.
- Plan 4 adds audit persistence and run-state tracking.
- Plan 5 exposes approval submission through UniFFI.
- Plan 7 implements the Swift UI and LocalAuthentication integration point.

### 6. UniFFI / Swift Bridge Gaps

Assessment: reasonable.

There is no FFI layer yet. This should not be started before Rust tool lifecycle
and persistent runtime semantics are clear.

Planning decision:

- Plan 5 starts UniFFI after Plan 3 and Plan 4 stabilize the Rust surface.
- The bridge must expose DTOs and event streams, not Rust internal objects.

## Planning Rule Added

Before each new detailed implementation plan is written:

1. Read the current relevant code files.
2. Run targeted `rg` checks for the capability the plan claims to implement.
3. Compare the requested/report gaps against actual code.
4. Add a "Current Code Audit" section to the plan.
5. Assign each valid gap to the current plan, a later MVP plan, or a post-MVP
   backlog item.
