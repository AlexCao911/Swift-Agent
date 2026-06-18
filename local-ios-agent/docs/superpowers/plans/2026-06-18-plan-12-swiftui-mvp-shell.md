# Plan 12: SwiftUI Frontend MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SwiftUI MVP that composes the runtime bridge, native toolkit, and provider layer into a usable local iOS agent shell.

**Architecture:** Plan 12 is the composition and presentation layer. SwiftUI does not own runtime state, native tool definitions, provider behavior, or inference. It wires Plan 8 `RuntimeClient`, Plan 9 `NativeToolCatalog`/`NativeToolExecutor`, and Plan 10 `ProviderControllingRuntimeClient` into an app flow: register schemas at startup, send messages, render events, handle approvals, drain pending tools, and display provider/debug state.

**Tech Stack:** Swift Package Manager, Swift 5.9, SwiftUI, XCTest, Plan 8 `LocalAgentBridge`, Plan 9 `LocalNativeToolkit`, Plan 10 `ProviderControllingRuntimeClient`, TDD.

---

## Current Code Audit

Expected after Plans 8-11:

- `RuntimeClient` can call Rust.
- Native toolkit can export schemas and execute tool requests.
- Provider selection is exposed through the runtime bridge.
- On-device provider exists as a selectable boundary option.

Still missing:

- SwiftUI app target;
- app bootstrap/composition;
- chat state projection;
- provider settings UI;
- approval sheet;
- tool/audit rows;
- prompt debug view;
- MVP acceptance runbook.

Hard constraint:

- If the bridge, provider, or toolkit contract is missing, Plan 12 must stop at
  protocol integration and tests. It must not add temporary SwiftUI-only mocks
  or local state that pretends to implement missing lower-layer behavior.

## Ownership Boundary

Plan 12 owns:

- app composition/bootstrap;
- SwiftUI views;
- `AgentViewModel`;
- registering native schemas with runtime at startup;
- draining pending tool requests;
- submitting native tool results back to runtime;
- provider selector UI that calls runtime provider APIs;
- approval sheet UI;
- prompt debug UI;
- MVP acceptance runbook.

Plan 12 does not own:

- Rust bridge internals;
- native tool definitions;
- LLM provider implementation;
- C++ inference backend;
- Rust runtime state machine.

## Integration Flow

Startup:

```text
Create RuntimeClient
Require ProviderControllingRuntimeClient for provider UI
Create NativeToolCatalog
Create NativeToolExecutor
Register catalog.schemas through RuntimeClient.registerToolSchema
Load provider profiles through ProviderControllingRuntimeClient
```

User turn:

```text
sendMessage
  -> apply returned runtime events
  -> refresh pending approvals
  -> drain pending tool requests until completed, suspended, failed, or empty
```

Tool drain:

```text
pendingToolRequests
  -> filter request.runId == activeTurn.runId
  -> NativeToolExecutor.execute(request)
  -> RuntimeClient.submitToolResult(runId, result)
  -> apply continuation turn
  -> repeat
```

Provider selection:

```text
ProviderSettingsView selection
  -> ProviderControllingRuntimeClient.setProvider(sessionId, providerId)
  -> render ProviderChanged event
```

## Run Safety Rules

- `RuntimeClient.pendingToolRequests()` is global. `AgentViewModel` must filter
  requests by the current turn's `runId` before executing any native tool.
- The drain loop must track an execution key per user turn:

```text
runId + toolName + canonicalArgumentsJson
```

- If the same key appears again without a new user action, stop draining and
  surface a model-visible duplicate-tool-loop error instead of executing the same
  native side effect repeatedly.
- The drain loop must also enforce a small continuation cap, such as 16 tool
  executions per user turn, and stop with a visible error if the cap is reached.
- Provider switching is disabled in UI while the current session has an active,
  suspended, streaming, waiting-tool, or waiting-approval run. Plan 10 still owns
  the authoritative runtime rejection for racy calls.

## File Structure

Create:

```text
local-ios-agent/ios-app/Sources/LocalAgentApp/AppBootstrap.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/AgentViewModel.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ChatView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ProviderSettingsView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ApprovalSheetView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/PromptDebugView.swift
local-ios-agent/ios-app/Sources/LocalAgentApp/ToolAuditRow.swift
local-ios-agent/ios-app/Tests/LocalAgentAppTests/AppBootstrapTests.swift
local-ios-agent/ios-app/Tests/LocalAgentAppTests/AgentViewModelTests.swift
local-ios-agent/docs/mvp-acceptance.md
```

Modify:

```text
local-ios-agent/ios-app/Package.swift
```

## Task 1: Add App Bootstrap

- [ ] Build the default native tool catalog.
- [ ] Build the native tool executor.
- [ ] Register exported tool schemas into `RuntimeClient`.
- [ ] Load provider profile state through `ProviderControllingRuntimeClient`.
- [ ] Fail fast in tests if a real provider-control capability is not supplied
  for provider UI.
- [ ] Add tests proving bootstrap registers every native schema exactly once.

## Task 2: Add Agent View Model

- [ ] Create session on first send.
- [ ] Apply runtime events into view state.
- [ ] Fetch pending approvals after each turn.
- [ ] Implement `drainPendingToolRequests`.
- [ ] Filter pending tool requests by the active turn `runId`.
- [ ] Track duplicate drain keys using `runId + toolName +
  canonicalArgumentsJson`.
- [ ] Stop and surface an error when a duplicate drain key or continuation cap
  is reached.
- [ ] Stop draining when runtime is suspended, failed, cancelled, completed with
  no pending tool, or when executor returns unrecoverable error.
- [ ] Add tests proving tool requests are executed and submitted back to runtime.
- [ ] Add tests proving another run's pending tools are not executed.
- [ ] Add tests proving repeated identical tool calls stop instead of looping
  forever.

## Task 3: Add Chat and Tool/Audit UI

- [ ] Add chat message list.
- [ ] Add composer.
- [ ] Add tool/audit disclosure rows.
- [ ] Keep UI as projection of view-model state.

## Task 4: Add Approval UI

- [ ] Add approval sheet.
- [ ] Approve calls `RuntimeClient.submitApprovalResponse`.
- [ ] Reject calls `RuntimeClient.submitApprovalResponse` with rejected state.
- [ ] Continue event application after approval response.

## Task 5: Add Provider Settings UI

- [ ] Render provider profiles from runtime.
- [ ] Render active provider from runtime.
- [ ] Require `ProviderControllingRuntimeClient`.
- [ ] Call `ProviderControllingRuntimeClient.setProvider` on selection.
- [ ] Disable provider selection while the current session has an active or
  suspended run.
- [ ] Render the runtime's provider-switch-blocked error if a racy call is
  rejected anyway.
- [ ] Render `ProviderChanged` outcome.
- [ ] Do not store provider selection as UI-only state.

## Task 6: Add Prompt Debug View and Acceptance Runbook

- [ ] Render latest prompt debug snapshot from runtime.
- [ ] Add MVP acceptance runbook covering mock chat, tool lifecycle, approval
  lifecycle, provider switching, and prompt debug visibility.

## Verification

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test
swift build
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test
```

## Self-Review

- Plan 12 composes existing layers; it does not redefine them.
- Plan 12 never fills lower-layer contract gaps with SwiftUI-only behavior.
- Tool draining belongs here because it is app workflow orchestration.
- Tool draining is run-scoped and loop-guarded; it must not execute pending
  requests from another run.
- Provider selection UI calls runtime provider APIs instead of mutating local UI
  state only.
- Provider switching during active runs is blocked by UI affordance and by the
  Plan 10 runtime contract.
