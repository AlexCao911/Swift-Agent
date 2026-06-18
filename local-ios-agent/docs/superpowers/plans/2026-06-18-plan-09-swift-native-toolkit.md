# Plan 9: Swift Native Toolkit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Swift native capability layer: tool schemas, tool catalog, permission modeling, and native executors.

**Architecture:** Plan 9 is a native-toolkit plan, not a runtime bridge plan. The toolkit defines what native tools exist and how Swift executes them. It does not own Rust runtime state, app composition, or SwiftUI flow control. It exports schemas and executes requests; Plan 12 decides when to register schemas and when to submit tool results.

**Tech Stack:** Swift Package Manager, Swift tools 6.0, Swift Testing, Foundation, Plan 8 DTOs, TDD.

---

## Current Code Audit

Expected after Plan 8:

- `ToolSchemaDTO`, `ToolExecutionRequestDTO`, and `ToolResultDTO` exist.
- `RuntimeClient.registerToolSchema` exists, but the toolkit does not call it
  by itself.

Runtime facts:

- Rust routes model tool calls into `ToolExecutionRequest`.
- Rust waits for Swift to return `ToolResult`.
- Confirm-level tools can produce approval requests before execution.

## Ownership Boundary

Plan 9 owns:

- `NativeTool` protocol.
- `NativeToolSchema`.
- `NativeToolCatalog`.
- `PermissionStore`.
- `NativeToolExecutor`.
- Schema export from native tools into `ToolSchemaDTO`.
- Basic meta tools.
- First native tool boundaries for Calendar, Reminders, and Shortcuts.

Plan 9 does not own:

- calling `RuntimeClient.registerToolSchema` during app startup;
- draining runtime pending tool requests;
- rendering approval UI;
- provider selection;
- SwiftUI screens.

## Integration Points

- Plan 12 will compose `NativeToolCatalog` with `RuntimeClient` and register all
  exported schemas during app bootstrap.
- Plan 12 will call `NativeToolExecutor.execute(request)` for pending tool
  requests, then call `RuntimeClient.submitToolResult`.
- Plan 8 provides DTOs and bridge methods used by the toolkit but does not know
  about native tool implementations.

## Schema Contract

`NativeToolSchema` is the Swift-native source of truth for a tool. It is a
superset of the bridge schema because native execution needs permission and
availability metadata that the model should not control directly.

Required shape:

```swift
public struct NativeToolSchema: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONSchemaDTO
    public var riskLevel: NativeToolRiskLevel
    public var permissionScope: NativePermissionScope?
    public var availability: NativeToolAvailability
}
```

`NativeToolSchemaExport` performs a one-way projection:

```text
NativeToolSchema
  -> ToolSchemaDTO
```

Mapping rules:

- `name`, `description`, and `inputSchema` copy into the bridge DTO unchanged.
- `NativeToolRiskLevel` maps deterministically to the bridge/Rust tool risk
  level.
- `permissionScope` is exported only as metadata for audit/debug visibility; it
  is not trusted as an authorization decision by Rust or the model.
- `availability` is toolkit-only and determines whether the schema is exported
  at all.
- Conversion never mutates `NativeToolSchema` and never registers the schema
  with `RuntimeClient`; Plan 12 owns registration timing.

## File Structure

Create:

```text
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeTool.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolCatalog.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolExecutor.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/PermissionStore.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/MetaTools.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/CalendarTools.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/ReminderTools.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/ShortcutTools.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolCatalogTests.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolSchemaExportTests.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolTests.swift
```

Modify:

```text
local-ios-agent/ios-app/Package.swift
```

## Task 1: Define Native Tool Model

- [ ] Add `NativeToolRiskLevel`, `NativeToolSchema`, `NativePermissionState`,
  `NativePermissionScope`, `NativeToolAvailability`, `PermissionStore`, and
  `NativeTool`.
- [ ] Add `NativeToolCatalog` with duplicate-name rejection and deterministic
  schema ordering.
- [ ] Add tests for schema ordering, duplicate rejection, and permission state.

## Task 2: Export Schemas

- [ ] Add `NativeToolSchemaExport`.
- [ ] Map native risk levels to bridge `ToolSchemaDTO` risk levels.
- [ ] Preserve permission scope metadata as exported metadata, not behavior.
- [ ] Omit unavailable native tools from exported schemas.
- [ ] Add tests proving exported schemas match the Rust bridge DTO shape.

## Task 3: Add Native Executor

- [ ] Add `NativeToolExecutor`.
- [ ] Execute by `ToolExecutionRequestDTO.toolName`.
- [ ] Return model-visible errors for unknown tools and invalid arguments.
- [ ] Do not call `RuntimeClient` from the executor.

## Task 4: Add Basic Meta Tools

- [ ] Add `native.list_tools`.
- [ ] Add `native.permission_status`.
- [ ] Keep both read-only, public, and run-scoped.

## Task 5: Add First Native Capability Boundaries

- [ ] Add `calendar.search_events` through an injectable calendar facade.
- [ ] Add `reminders.create_reminder` through an injectable reminders facade.
- [ ] Add `shortcuts.list_voice_shortcuts` through an injectable shortcuts
  facade.
- [ ] Keep real framework prompts and entitlements outside this plan.

## Verification

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test
swift build
```

## Self-Review

- Plan 9 defines native tools but does not register them into Rust by itself.
- Plan 9 executes native tools but does not submit results to Rust by itself.
- `NativeToolSchema` is the native superset; `ToolSchemaDTO` is its bridge
  projection.
- Plan 9 remains reusable by tests and future UI surfaces.
