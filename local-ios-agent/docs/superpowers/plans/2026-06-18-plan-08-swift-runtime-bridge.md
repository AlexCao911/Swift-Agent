# Plan 8: Swift Runtime Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose the existing Rust runtime to Swift through a small, typed bridge surface.

**Architecture:** Plan 8 is a bridge plan, not a product-feature plan. Rust remains authoritative for sessions, run state, events, tool routing, approvals, and prompt construction. Swift receives typed DTOs through `RuntimeClient`; the concrete `RustRuntimeClient` owns C/FFI calls and JSON decoding, while `MockRuntimeClient` is only a test double. Provider-specific control, native tool execution, and UI orchestration are deliberately outside the base bridge.

**Tech Stack:** Rust 2021, existing `AgentRuntime`, C ABI or UniFFI-ready JSON boundary, Swift Package Manager, Swift 5.9, XCTest, TDD.

---

## Current Code Audit

Existing Rust runtime APIs:

- `create_session`
- `send_message_turn`
- `submit_tool_result`
- `cancel`
- `pending_tool_requests`
- `pending_approval_requests`
- `submit_approval_response`
- `session_ids`

Bridge gaps:

- no Swift package;
- no Swift DTOs;
- no `RuntimeClient`;
- no `RustRuntimeClient`;
- no C/Swift module linkage;
- no bridge-level JSON conversion tests;
- no generic bridge method for tool schema registration.

## Ownership Boundary

Plan 8 owns:

- Swift DTOs for runtime events, turn results, tool schemas, tool requests,
  tool results, approval requests, approval responses, session IDs, and
  prompt debug snapshots.
- `RuntimeClient` protocol.
- `MockRuntimeClient` test double.
- `RustRuntimeClient` concrete bridge client.
- C ABI or UniFFI-ready functions that expose existing runtime operations.
- Generic `registerToolSchema` bridge capability.

Plan 8 does not own:

- native tool implementations;
- provider implementations;
- provider selection UI;
- SwiftUI chat screens;
- app-level draining of pending tool requests;
- C++ inference backend behavior.

## Integration Points

- Plan 9 will provide native tool schemas and executors. Plan 8 only provides
  the generic method that can register a schema.
- Plan 10 will add a separate `ProviderControllingRuntimeClient` capability for
  provider-list and provider-selection methods. Plan 8 should not silently grow
  provider-specific methods on the base `RuntimeClient`.
- Plan 12 will compose the real app by calling `RuntimeClient`, registering
  native schemas, draining pending tools, and rendering UI state.
- Prompt debug snapshot generation is not owned by this bridge. Plan 8 only
  defines and transports `PromptDebugSnapshotDTO`; the Rust runtime/provider
  hardening work that captures the latest prompt snapshot is owned by Plan 10.

## Runtime Client Contract

Plan 8 should produce this base surface:

```swift
public protocol RuntimeClient: Sendable {
    func createSession() async throws -> String
    func sessionIds() async throws -> [String]
    func registerToolSchema(_ schema: ToolSchemaDTO) async throws
    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO
    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO]
    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO]
    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO
    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO
    func cancel(runId: String) async throws -> RuntimeEventDTO
    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO?
}
```

Provider-specific methods are intentionally excluded from the base contract.
Plan 10 adds a separate provider-control protocol instead of changing the
meaning of `RuntimeClient`.

`sessionIds()` deliberately mirrors the Rust runtime's existing `session_ids()`
capability. Plan 8 must not invent richer session metadata unless Rust first
grows a real method that owns timestamps, titles, or branch metadata.

`ToolExecutionRequestDTO` must include `runId` / `run_id` as a required field so
Plan 12 can filter global pending tool requests down to the active turn before
executing any native tool.

`latestPromptDebugSnapshot()` is a bridge read method. It may return `nil` until
Plan 10 wires runtime prompt snapshot capture into provider calls.

## File Structure

Create:

```text
local-ios-agent/ios-app/Package.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeDTOs.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeClient.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/MockRuntimeClient.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/RustRuntimeClient.swift
local-ios-agent/ios-app/Sources/CLocalAgentRuntime/include/CLocalAgentRuntime.h
local-ios-agent/ios-app/Sources/CLocalAgentRuntime/module.modulemap
local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift
local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift
local-ios-agent/rust-core/src/ffi_bridge.rs
local-ios-agent/rust-core/tests/ffi_bridge.rs
```

Modify:

```text
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/rust-core/src/core/runtime.rs
local-ios-agent/rust-core/src/lib.rs
local-ios-agent/rust-core/src/tool/router.rs
```

## Task 1: Define Bridge DTOs

- [ ] Add Swift DTOs with snake_case JSON compatibility.
- [ ] Add tests proving Rust-shaped JSON decodes into Swift DTOs.
- [ ] Add tests proving Swift encodes `ToolResultDTO` and `ToolSchemaDTO` in
  the shape Rust expects.

## Task 2: Add Generic Rust Bridge Facade

- [ ] Add `AgentRuntime::register_tool` as a generic runtime capability.
- [ ] Add `ToolRouter::register` as the narrow way to update the Rust registry.
- [ ] Add `RuntimeJsonBridge` methods for create session, send message, cancel,
  pending tools, pending approvals, submit tool result, submit approval response,
  session IDs, prompt debug snapshot, and tool schema registration.
- [ ] Add Rust tests that prove bridge JSON is stable and model/tool lifecycle
  calls reach the existing runtime.

## Task 3: Add C ABI / Module Linkage

- [ ] Add C ABI functions that wrap `RuntimeJsonBridge`.
- [ ] Guarantee every returned string is caller-owned and freed through one
  bridge function.
- [ ] Add the Swift C header and module map.
- [ ] Add smoke tests for pointer ownership and JSON error payloads.

## Task 4: Add Swift Runtime Clients

- [ ] Add `RuntimeClient`.
- [ ] Add `MockRuntimeClient` with deterministic behavior for UI/toolkit tests.
- [ ] Add `RustRuntimeClient` that calls the C bridge, decodes DTOs, throws
  bridge errors, and releases runtime resources.
- [ ] Add Swift contract tests using an injectable C function table.

## Verification

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test
swift build
```

## Self-Review

- Plan 8 exposes Rust to Swift but does not implement native tools.
- Plan 8 exposes generic schema registration but does not decide which native
  schemas exist.
- Plan 8 leaves provider-specific bridge methods to Plan 10's separate
  `ProviderControllingRuntimeClient` capability.
- Plan 8 bridges prompt debug snapshots but does not create them.
- Plan 8 exposes session IDs only; richer session metadata requires a future
  Rust runtime API.
