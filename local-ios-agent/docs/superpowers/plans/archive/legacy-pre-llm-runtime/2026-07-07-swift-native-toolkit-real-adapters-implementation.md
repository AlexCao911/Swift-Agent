# Swift Native Toolkit Real Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the debug-only host tool path with a production-shaped Swift native toolkit route, then connect the first real iOS system adapters that Builder-selected agents can use.

**Architecture:** This is the second product-side plan after `2026-07-07-swift-agent-builder-ui-implementation.md`. It keeps the toolkit as a Swift-owned platform boundary: Rust sees schemas and structured tool results; Swift owns Apple framework calls, permissions, foreground UI, attachments, and pending user interaction recovery. The first slice registers and executes the native catalog before adding EventKit, Reminders, Files, Photos, Share, Vision, Speech, App Intents, and Maps.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, SwiftUI/UIKit presentation hooks, EventKit, PhotosUI, UniformTypeIdentifiers, VisionKit, Vision, Speech, CoreLocation/MapKit, AppIntents, `LocalAgentBridge`, `LocalNativeToolkit`, existing Xcode project `apps/LocalAgentApp/LocalAgentApp.xcodeproj`.

## Global Constraints

- Unless a step explicitly says otherwise, run shell commands from `local-ios-agent/`.
- Execute this plan after the Builder UI plan has made manifest-backed Tool Belt cards visible.
- Do not implement the final AppShell in this plan; add only the app hooks needed for toolkit execution and picker presentation.
- `NativeToolManifest` remains the single source for tool card labels, risk, permission scope, approval policy, fallback, audit, and trust metadata.
- Do not expose raw file paths, Photos asset URLs, security-scoped bookmark data, EventKit objects, or platform identifiers directly to the model.
- User-mediated tools must persist `PendingUserInteractionRecord` before presenting system UI.
- Files and Photos tools return `attachment_id + metadata`; byte/text reads happen through bounded attachment tools.
- EventKit permissions must keep `calendar.events.read_full`, `calendar.events.write_only`, and `calendar.events.user_confirmed_create` separate.
- Background tools must never present system UI; they return structured missing-permission or unavailable errors.
- `web.fetch_url_text` is a bounded public-HTTPS text fetch tool. It must reject URL userinfo, cookies/auth headers, non-HTTPS schemes, disallowed MIME types, excessive redirects, and known private-network host literals. Resolved-address private-network protection is a documented hardening item unless implemented in this plan.
- App Intents and Shortcuts are system action adapters for app-owned actions, not arbitrary user Shortcut execution.

---

## Cross-Document Execution Alignment

| Product path | Plan file | Relationship |
| --- | --- | --- |
| Agent Builder UI | `2026-07-07-swift-agent-builder-ui-implementation.md` | Must run first. Builder shows and selects tool manifests. |
| Native Toolkit Real Adapters | this file | Runs second. Selected tools become executable through real Swift adapters. |
| Full App Product Frontend | `2026-07-07-swift-app-product-frontend-implementation.md` | Runs third. Tool Center, approval cards, pending interaction cards, and context disclosure become polished app UX. |

The core acceptance chain for this plan is:

```text
Builder selects tool
  -> schema is exported from NativeToolManifest
  -> Rust requests tool call
  -> Swift NativeToolExecutor executes real adapter
  -> ToolResultEnvelopeV1 returns to Rust
  -> Chat receives normal tool result
```

## File Structure

Toolkit package files:

- Modify `toolkit/Sources/LocalNativeToolkit/NativeToolCatalog.swift`
  Adds small catalog factory helpers used by the app composition layer.
- Modify `toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`
  Ensures production export fails closed for tools without manifests.
- Modify `toolkit/Sources/LocalNativeToolkit/NativeToolExecutor.swift`
  Keeps envelope validation mandatory for first-party tools and attaches the runtime `tool_call_id`.
- Create `toolkit/Sources/LocalNativeToolkit/Permissions/NativePermissionGateway.swift`
  Defines the platform-neutral permission gateway and repair metadata returned by tools.
- Create `toolkit/Sources/LocalNativeToolkit/Permissions/EventKitPermissionAdapter.swift`
  Maps EventKit calendar/reminder authorization state to native permission scopes.
- Create `toolkit/Sources/LocalNativeToolkit/EventKit/EventKitCalendarAdapter.swift`
  Real `CalendarEventsFacade` implementation.
- Create `toolkit/Sources/LocalNativeToolkit/EventKit/EventKitReminderAdapter.swift`
  Real `RemindersFacade` implementation.
- Modify `toolkit/Sources/LocalNativeToolkit/WebFetchPolicy.swift`
  Hardens URL userinfo, IPv6 private literals, redirect validation, and policy error codes.
- Modify `toolkit/Sources/LocalNativeToolkit/WebTools.swift`
  Preserves web policy denial codes and keeps external content trust metadata.
- Create `toolkit/Sources/LocalNativeToolkit/Attachments/NativeAttachmentByteStore.swift`
  File-backed attachment byte store under the app container.
- Create `toolkit/Sources/LocalNativeToolkit/Attachments/AttachmentTools.swift`
  `files.describe_attachment`, `files.read_attachment`, and shared attachment envelope helpers.
- Create `toolkit/Sources/LocalNativeToolkit/UserMediated/FilePickerTool.swift`
  Tool request object for document picking, executed through the app presentation broker.
- Create `toolkit/Sources/LocalNativeToolkit/UserMediated/PhotosPickerTool.swift`
  Tool request object for image picking, executed through the app presentation broker.
- Create `toolkit/Sources/LocalNativeToolkit/SystemActions/AgentSystemActionIntents.swift`
  App-owned intent DTOs for capture/open actions where package boundaries allow it.

App files:

- Create `apps/LocalAgentApp/LocalAgentApp/Tools/NativeToolkitClient.swift`
  Builds the production catalog and exposes exported schemas plus execution.
- Create `apps/LocalAgentApp/LocalAgentApp/Tools/NativeHostToolDriver.swift`
  Replaces `MinimalHostToolDriver` for production native tool execution.
- Modify `apps/LocalAgentApp/LocalAgentApp/Tools/MinimalHostToolDriver.swift`
  Marks `debug.echo` as development-only and removes it from production native catalog export.
- Modify `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
  Registers native schemas and injects the native host tool driver.
- Modify `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
  Owns `NativeToolkitClient`, permission gateway, attachment store, and pending interaction store.
- Create `apps/LocalAgentApp/LocalAgentApp/Tools/NativeInteractionBroker.swift`
  Presents Files/Photos/Vision/Speech flows only after pending interaction has been persisted.
- Modify `apps/LocalAgentApp/LocalAgentApp/AppIntents/LocalAgentShortcuts.swift`
  Adds capture/open Builder actions that route through app-owned destinations.
- Modify `apps/LocalAgentApp/LocalAgentApp/Resources/Info.plist`
  Adds required usage strings as adapters become active.

Tests:

- Create `toolkit/Tests/LocalNativeToolkitTests/NativePermissionGatewayTests.swift`
- Create `toolkit/Tests/LocalNativeToolkitTests/EventKitAdapterContractTests.swift`
- Create `toolkit/Tests/LocalNativeToolkitTests/WebFetchPolicyHardeningTests.swift`
- Create `toolkit/Tests/LocalNativeToolkitTests/AttachmentToolTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeToolkitClientTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeHostToolDriverTests.swift`
- Create `apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeInteractionBrokerTests.swift`

---

### Task 1: Register And Execute Native Catalog

**Files:**
- Modify: `toolkit/Sources/LocalNativeToolkit/NativeToolSchemaExport.swift`
- Modify: `toolkit/Sources/LocalNativeToolkit/MetaTools.swift`
- Test: `toolkit/Tests/LocalNativeToolkitTests/NativeToolSchemaExportTests.swift`
- Test: `toolkit/Tests/LocalNativeToolkitTests/MetaToolsTests.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Tools/NativeToolkitClient.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Tools/NativeHostToolDriver.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Tools/MinimalHostToolDriver.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeToolkitClientTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeHostToolDriverTests.swift`

**Interfaces:**

```swift
struct NativeToolkitRegistrationSnapshot: Equatable, Sendable {
    var schemas: [ToolSchemaDTO]
    var toolNames: [String]
}

protocol NativeToolkitClientProtocol: Sendable {
    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot
    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO
}

actor NativeToolkitClient: NativeToolkitClientProtocol {
    init(catalog: NativeToolCatalog)
    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot
    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO
}

actor NativeHostToolDriver {
    init(toolkit: any NativeToolkitClientProtocol, maxContinuations: Int = 8)
    func schemas() async -> [ToolSchemaDTO]
    func execute(_ request: ToolExecutionRequestDTO, continuationIndex: Int) async -> ToolResultDTO?
}
```

- [ ] **Step 1: Rewrite schema export contract tests**

Modify `NativeToolSchemaExportTests.swift` so the old no-manifest expectations are replaced. The existing tests that allow manifest-less schemas to export must be rewritten; manifest-less schemas are omitted from production export.

Use this shape:

```swift
@Test("single schema export matches catalog export")
func singleSchemaExportMatchesCatalogExport() throws {
    let permissionStore = PermissionStore()
    let catalog = try NativeToolCatalog(tools: [
        NativePermissionStatusTool(permissionStore: permissionStore),
    ])
    let schema = try #require(catalog.schemas.first)

    let single = try #require(NativeToolSchemaExport.export(schema))
    let all = NativeToolSchemaExport.exportSchemas(from: catalog)

    #expect(all == [single])
    #expect(single.metadataJson?.contains(#""schema_version":1"#) == true)
}

@Test("schema without manifest is not exported")
func schemaWithoutManifestIsNotExported() {
    let schema = NativeToolSchema(
        name: "debug.unmanifested",
        description: "A tool without a manifest.",
        inputSchema: .object(),
        riskLevel: .readOnly,
        permissionScope: nil,
        availability: .available,
        manifest: nil
    )

    #expect(NativeToolSchemaExport.export(schema) == nil)
}

@Test
func exportsAvailableManifestBackedSchemasInBridgeDTOShape() throws {
    let manifest = NativeToolManifest(
        manifestId: "native.calendar.search_events.v1",
        capabilityId: "calendar.events.search",
        title: "Search Calendar",
        description: "Search calendar events",
        mode: .background,
        permissionScope: NativePermissionScope("calendar.events.read_full"),
        requiredPrivacyKeys: ["NSCalendarsFullAccessUsageDescription"],
        requiresForegroundUI: false,
        minimumOS: "iOS 17.0",
        regionPolicy: "available_with_service_fallback",
        fallback: NativeToolFallback(kind: .openSettings, message: "Calendar access is required."),
        riskLevel: .confirm,
        approvalPolicy: .perCall,
        trustLevel: .trustedToolResult,
        retention: .runOnly,
        audit: NativeToolAudit(label: "Calendar Search", resultSummaryPolicy: .metadataOnly)
    )
    let parameters = #"{"type":"object","properties":{"query":{"type":"string"}}}"#
    let catalog = try NativeToolCatalog(tools: [
        ExportStubTool(
            schema: NativeToolSchema(
                name: "calendar.search_events",
                description: "Search calendar events",
                inputSchema: JSONSchemaDTO(jsonString: parameters),
                riskLevel: .readOnly,
                permissionScope: NativePermissionScope("calendar.events.read_full"),
                availability: .available,
                manifest: manifest
            )
        ),
        ExportStubTool(
            schema: NativeToolSchema(
                name: "legacy.unmanifested",
                description: "Should not export",
                inputSchema: .object(),
                riskLevel: .readOnly,
                permissionScope: nil,
                availability: .available,
                manifest: nil
            )
        ),
    ])

    let exported = NativeToolSchemaExport.exportSchemas(from: catalog)

    #expect(exported.map(\.name) == ["calendar.search_events"])
    #expect(exported[0].description == "Search calendar events")
    #expect(exported[0].parametersJsonSchema == parameters)
    #expect(exported[0].riskLevel == .confirm)
    #expect(exported[0].metadataJson != nil)
}
```

- [ ] **Step 2: Run package export test and verify failure**

Run:

```bash
swift test --package-path toolkit --filter NativeToolSchemaExportTests
```

Expected: FAIL because `NativeToolSchemaExport.export(_:)` does not exist.

- [ ] **Step 3: Add `NativeToolSchemaExport.export(_:)`**

Modify `NativeToolSchemaExport.swift` so `exportSchemas(from:)` delegates to the new single-schema API:

```swift
public enum NativeToolSchemaExport {
    public static func exportSchemas(from catalog: NativeToolCatalog) -> [ToolSchemaDTO] {
        catalog.schemas.compactMap { export($0) }
    }

    public static func export(_ schema: NativeToolSchema) -> ToolSchemaDTO? {
        guard schema.availability == .available else {
            return nil
        }
        guard let manifest = schema.manifest else {
            return nil
        }
        let effectiveRisk = effectiveRiskLevel(schema.riskLevel, manifest.riskLevel)

        return ToolSchemaDTO(
            name: schema.name,
            description: schema.description,
            parametersJsonSchema: schema.inputSchema.jsonString,
            riskLevel: bridgeRiskLevel(for: effectiveRisk),
            metadataJson: metadataJSON(for: schema)
        )
    }
}
```

Keep the existing private `metadataJSON`, `effectiveRiskLevel`, and `availabilityState` helpers. This fail-closed guard is product behavior: debug-only tools without manifests can exist in tests or development drivers, but they must not appear in the production native schema export.

- [ ] **Step 4: Run package export test**

Run:

```bash
swift test --package-path toolkit --filter NativeToolSchemaExportTests
```

Expected: PASS.

- [ ] **Step 5: Make `native.list_tools` use the same fail-closed visibility**

Modify `MetaTools.swift` so `NativeListToolsTool` filters through the same export contract:

```swift
let toolSummaries = catalogProvider().schemas
    .compactMap { schema -> ToolSummary? in
        guard let exported = NativeToolSchemaExport.export(schema),
              let metadata = exported.metadataJson.flatMap(Self.decodeMetadata)
        else {
            return nil
        }
        return ToolSummary(
            name: exported.name,
            riskLevel: exported.riskLevel,
            permissionScope: metadata.permissionScope
        )
    }
    .sorted { $0.name < $1.name }

private struct ToolSummary {
    var name: String
    var riskLevel: RiskLevelDTO
    var permissionScope: String?
}

private static func decodeMetadata(_ json: String) -> NativeToolSchemaMetadataV1? {
    guard let data = json.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(NativeToolSchemaMetadataV1.self, from: data)
}
```

Extend `MetaToolsTests.swift` with:

- a catalog containing one manifest-backed tool and one manifest-less available tool; assert that `native.list_tools` includes only the manifest-backed tool
- a schema whose raw risk is `.readOnly` and manifest risk is `.confirm`; assert `native.list_tools` reports `confirm`, matching exported `ToolSchemaDTO.riskLevel`

- [ ] **Step 6: Run meta tool tests**

Run:

```bash
swift test --package-path toolkit --filter MetaToolsTests
```

Expected: PASS.

- [ ] **Step 7: Write failing registration tests**

Create `NativeToolkitClientTests.swift` with a fake catalog containing `native.list_tools`, `native.permission_status`, `web.fetch_url_text`, and one manifest-less available tool. Assert that:

- `registrationSnapshot().schemas` is sorted by name
- every exported schema contains manifest metadata JSON
- `debug.echo` is not exported
- the manifest-less available tool is not exported
- executing the manifest-less available tool returns a structured `native_tool_unavailable` error instead of calling the raw tool

- [ ] **Step 8: Run focused app tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/NativeToolkitClientTests
```

Expected: FAIL because `NativeToolkitClient` does not exist.

- [ ] **Step 9: Implement `NativeToolkitClient`**

Use `NativeToolSchemaExport.export(_:)` for every catalog schema. If a schema lacks a manifest in product mode, omit it and record the omission in a local diagnostic array rather than creating a legacy manifest.

Implementation shape:

```swift
import Foundation
import LocalAgentBridge
import LocalNativeToolkit

struct NativeToolkitRegistrationSnapshot: Equatable, Sendable {
    var schemas: [ToolSchemaDTO]
    var toolNames: [String]
}

protocol NativeToolkitClientProtocol: Sendable {
    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot
    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO
}

actor NativeToolkitClient: NativeToolkitClientProtocol {
    private let catalog: NativeToolCatalog
    private let executor: NativeToolExecutor

    init(catalog: NativeToolCatalog) {
        self.catalog = catalog
        self.executor = NativeToolExecutor(catalog: catalog)
    }

    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot {
        let schemas = catalog.schemas
            .compactMap { NativeToolSchemaExport.export($0) }
            .sorted { $0.name < $1.name }
        return NativeToolkitRegistrationSnapshot(
            schemas: schemas,
            toolNames: schemas.map(\.name).sorted()
        )
    }

    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        let exportedToolNames = Set(catalog.schemas.compactMap { NativeToolSchemaExport.export($0)?.name })
        guard exportedToolNames.contains(request.toolName) else {
            return NativeToolResultBuilder.error(
                manifestId: "native.toolkit.client.v1",
                toolName: request.toolName,
                toolCallId: request.toolCallId,
                code: "native_tool_unavailable",
                displayText: "Native tool is not available.",
                auditSummary: "Rejected unavailable native tool: \(request.toolName)"
            )
        }
        await executor.execute(request)
    }
}
```

- [ ] **Step 10: Add native host driver tests**

Create `NativeHostToolDriverTests.swift` and cover:

- unknown tool returns a structured error envelope
- manifest-less available tool is rejected before `NativeToolExecutor` can call the raw tool
- duplicate `tool_call_id` returns `nil`
- continuation limit returns an error envelope
- successful native result preserves `tool_call_id`

- [ ] **Step 11: Implement `NativeHostToolDriver`**

Keep `MinimalHostToolDriver` available for tests/development, but production bootstrap must depend on `NativeHostToolDriver`.

Implementation rule:

```swift
guard completedToolCallIds.insert(request.toolCallId).inserted else {
    return nil
}
return await toolkit.execute(request)
```

- [ ] **Step 12: Wire bootstrap**

Modify `AppBootstrapper` so native schemas are registered from `NativeToolkitClient.registrationSnapshot()` and tool execution uses `NativeHostToolDriver`.

The first production catalog should contain:

```swift
NativeListToolsTool(catalogProvider: { catalog })
NativePermissionStatusTool(permissionStore: permissionStore)
WebFetchURLTextTool()
```

Calendar/reminders tools are added in Task 3 after real adapters and permission gateway exist.

- [ ] **Step 13: Verify**

Run:

```bash
swift test --package-path toolkit --filter LocalNativeToolkitTests
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/NativeToolkitClientTests -only-testing:LocalAgentAppTests/NativeHostToolDriverTests
```

Expected: PASS. If Xcode cannot run in the current environment, record the toolchain limitation and keep the SwiftPM package tests passing.

---

### Task 2: Permission Gateway And Tool Readiness

**Files:**
- Create: `toolkit/Sources/LocalNativeToolkit/Permissions/NativePermissionGateway.swift`
- Create: `toolkit/Sources/LocalNativeToolkit/Permissions/EventKitPermissionAdapter.swift`
- Modify: `toolkit/Sources/LocalNativeToolkit/PermissionStore.swift`
- Test: `toolkit/Tests/LocalNativeToolkitTests/NativePermissionGatewayTests.swift`

**Interfaces:**

```swift
public enum NativePermissionReadiness: Equatable, Sendable {
    case ready
    case needsUserGrant(scope: NativePermissionScope, repair: NativePermissionRepair)
    case denied(scope: NativePermissionScope, repair: NativePermissionRepair)
    case unavailable(scope: NativePermissionScope, reason: String)
}

public enum NativePermissionRepairAction: Equatable, Sendable {
    case none
    case openSettings
    case requestPermission(scope: NativePermissionScope)
}

public struct NativePermissionRepair: Equatable, Sendable {
    public var title: String
    public var message: String
    public var action: NativePermissionRepairAction
}

public protocol NativePermissionGateway: Sendable {
    func readiness(for scope: NativePermissionScope?) async -> NativePermissionReadiness
    func requestPermission(for scope: NativePermissionScope) async -> NativePermissionReadiness
}
```

- [ ] **Step 1: Write failing permission tests**

Test exact scope behavior:

- `nil` scope is `.ready`
- `calendar.events.read_full` not-determined returns `.needsUserGrant` with `.requestPermission(scope:)`
- denied scope returns `.denied` with `.openSettings`
- `calendar.events.write_only` does not satisfy read access
- `reminders` denied does not satisfy `reminders.create_reminder`
- `requestPermission(for:)` returns the refreshed readiness state after the platform prompt or simulated grant

- [ ] **Step 2: Run package tests**

Run:

```bash
swift test --package-path toolkit --filter NativePermissionGatewayTests
```

Expected: FAIL because the gateway does not exist.

- [ ] **Step 3: Implement gateway**

Use `PermissionStore` for testable status and adapters for live platform checks. Keep the public type platform-neutral so Builder and Tool Center can show the same readiness metadata.

- [ ] **Step 4: Add EventKit adapter**

Use conditional imports:

```swift
#if canImport(EventKit)
import EventKit
#endif
```

Map EventKit states to native scopes:

```text
calendar.events.read_full -> requestFullAccessToEvents / full read-write event authorization
calendar.events.write_only -> requestWriteOnlyAccessToEvents / write-only event authorization
reminders -> reminder authorization
```

The adapter returns readiness and implements `requestPermission(for:)`; do not smuggle prompt callbacks through `NativePermissionReadiness`. Background tools still do not present permission UI themselves. Builder, Tool Center, or an app-owned repair surface may call `requestPermission(for:)` in response to an explicit user action.

- [ ] **Step 5: Verify**

Run:

```bash
swift test --package-path toolkit --filter NativePermissionGatewayTests
swift test --package-path toolkit --filter MetaToolsTests
```

Expected: PASS.

---

### Task 3: Real Background EventKit And Reminders Adapters

**Files:**
- Create: `toolkit/Sources/LocalNativeToolkit/EventKit/EventKitCalendarAdapter.swift`
- Create: `toolkit/Sources/LocalNativeToolkit/EventKit/EventKitReminderAdapter.swift`
- Modify: `toolkit/Sources/LocalNativeToolkit/CalendarTools.swift`
- Modify: `toolkit/Sources/LocalNativeToolkit/ReminderTools.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Composition/AppContainer.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/Resources/Info.plist`
- Test: `toolkit/Tests/LocalNativeToolkitTests/EventKitAdapterContractTests.swift`

**Interfaces:**

```swift
public struct EventKitCalendarAdapter: CalendarEventsFacade {
    public init(eventStore: EKEventStore)
    public func searchEvents(query: String) async throws -> [NativeCalendarEvent]
}

public struct EventKitReminderAdapter: RemindersFacade {
    public init(eventStore: EKEventStore)
    public func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder
}
```

- [ ] **Step 1: Write adapter contract tests using fakes**

Because CI may not have a real calendar database, tests should use an injectable facade around `EKEventStore` behavior. Assert:

- calendar search filters by query and returns sorted upcoming events
- reminder create writes title, notes, and optional due date
- missing permission maps to a structured tool error with private sensitivity

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --package-path toolkit --filter EventKitAdapterContractTests
```

Expected: FAIL because real adapters do not exist.

- [ ] **Step 3: Implement calendar adapter**

Search a bounded date window and return metadata only:

```text
id
title
start_date
end_date
```

Do not return location, notes, attendees, calendar names, or URLs in this first adapter.

- [ ] **Step 4: Implement reminder adapter**

Create reminders through EventKit. The first shipped tool remains `reminders.create_reminder`; `reminders.search` is not part of this plan.

- [ ] **Step 5: Add Info.plist keys**

Add:

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Local Agent uses calendar access only when an enabled agent tool searches your events.</string>
<key>NSCalendarsWriteOnlyAccessUsageDescription</key>
<string>Local Agent can create calendar events only after you choose an agent action that needs it.</string>
<key>NSRemindersUsageDescription</key>
<string>Local Agent uses reminders access only for enabled reminder tools.</string>
```

- [ ] **Step 6: Register tools in production catalog**

After permission gateway exists, add:

```swift
CalendarSearchEventsTool(calendar: EventKitCalendarAdapter(eventStore: eventStore))
RemindersCreateReminderTool(reminders: EventKitReminderAdapter(eventStore: eventStore))
```

- [ ] **Step 7: Verify**

Run:

```bash
swift test --package-path toolkit --filter EventKitAdapterContractTests
swift test --package-path toolkit --filter NativeToolResultEnvelopeTests
```

Expected: PASS. Manual simulator verification is needed before release because EventKit prompts and user databases are system behavior.

---

### Task 4: Web Fetch Hardening And Runtime Registration

**Files:**
- Modify: `toolkit/Sources/LocalNativeToolkit/WebFetchPolicy.swift`
- Modify: `toolkit/Sources/LocalNativeToolkit/WebTools.swift`
- Test: `toolkit/Tests/LocalNativeToolkitTests/WebFetchPolicyHardeningTests.swift`

**Interfaces:**

```swift
public struct WebFetchPolicyV1: Sendable, Equatable {
    public var maxRedirects: Int
    public var maxResponseBytes: Int
    public var maxExtractedTextCharacters: Int
    public var timeoutSeconds: TimeInterval
    public var allowPrivateNetworkLiterals: Bool
}
```

- [ ] **Step 1: Write security boundary tests**

Cover these inputs:

```text
https://user:pass@example.com -> web_fetch.credentials_denied
http://example.com -> web_fetch.scheme_denied
file:///etc/passwd -> web_fetch.scheme_denied
https://127.0.0.1 -> web_fetch.private_network_denied
https://[::1] -> web_fetch.private_network_denied
https://[fe80::1] -> web_fetch.private_network_denied
https://[fc00::1] -> web_fetch.private_network_denied
public URL redirecting to localhost -> web_fetch.private_network_denied
redirect count > maxRedirects -> web_fetch.too_many_redirects
```

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --package-path toolkit --filter WebFetchPolicyHardeningTests
```

Expected: FAIL for missing IPv6/userinfo coverage if not already implemented.

- [ ] **Step 3: Implement hardening**

Update `WebFetchPolicyV1.validate(_:)` and redirect validation:

- reject `url.user` and `url.password`
- reject `Authorization` and `Cookie`
- reject non-HTTPS
- reject private IPv4 literals
- reject private IPv6 literals: `::1`, `fc00::/7`, `fe80::/10`
- revalidate every redirect before following it
- preserve `WebFetchError.policyDenied(code)` in `WebFetchURLTextTool.execute`

- [ ] **Step 4: Record hardening boundary**

Add a short comment near the private host checker:

```swift
// This is a host-literal guard. It does not prove the resolved IP address is public.
// DNS rebinding / split-horizon DNS hardening belongs in the resolved-address fetch layer.
```

- [ ] **Step 5: Verify**

Run:

```bash
swift test --package-path toolkit --filter WebFetchPolicyHardeningTests
swift test --package-path toolkit --filter LocalNativeToolkitTests
```

Expected: PASS.

---

### Task 5: Attachment Store And User-Mediated Tool Foundation

**Files:**
- Create: `toolkit/Sources/LocalNativeToolkit/Attachments/NativeAttachmentByteStore.swift`
- Create: `toolkit/Sources/LocalNativeToolkit/Attachments/AttachmentTools.swift`
- Create: `toolkit/Sources/LocalNativeToolkit/UserMediated/FilePickerTool.swift`
- Create: `toolkit/Sources/LocalNativeToolkit/UserMediated/PhotosPickerTool.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/Tools/NativeInteractionBroker.swift`
- Test: `toolkit/Tests/LocalNativeToolkitTests/AttachmentToolTests.swift`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/Tools/NativeInteractionBrokerTests.swift`

**Interfaces:**

```swift
public struct NativeAttachmentStoredBytes: Equatable, Sendable {
    public var attachmentId: String
    public var filename: String
    public var contentType: String
    public var byteCount: Int
}

public protocol NativeAttachmentByteStore: Sendable {
    func put(_ data: Data, filename: String, contentType: String) async throws -> NativeAttachmentStoredBytes
    func read(attachmentId: String, maxBytes: Int) async throws -> Data
}
```

- [ ] **Step 1: Write attachment tests**

Assert:

- `put` returns an opaque `attachment_id`
- metadata does not include raw file path
- `read` respects `maxBytes`
- missing attachment returns a structured tool error
- `files.read_attachment` marks content from external files as `untrusted_external_content`

- [ ] **Step 2: Run failing tests**

Run:

```bash
swift test --package-path toolkit --filter AttachmentToolTests
```

Expected: FAIL because the byte store and tools do not exist.

- [ ] **Step 3: Implement file-backed byte store**

Store app-owned copies under Application Support. Do not expose storage URLs outside the toolkit.

- [ ] **Step 4: Implement describe/read tools**

Add:

```text
files.describe_attachment
files.read_attachment
photos.describe_attachment
```

Return metadata and bounded excerpts only.

- [ ] **Step 5: Implement pending interaction broker contract**

The broker must call the file-backed `PendingUserInteractionStore.put` before presenting any picker. Test this ordering with a fake store and fake presenter.

State transitions:

```text
requested -> presenting_system_ui -> completed
requested -> presenting_system_ui -> cancelled_by_user
requested -> failed
```

Use the existing `PendingInteractionState.failed` case for presentation failure. Do not introduce a separate presentation-failure enum value unless the toolkit DTO is deliberately migrated in the same task.

- [ ] **Step 6: Add picker tool request types**

Add `files.pick_document` and `photos.pick_images` as user-mediated tools that return a pending interaction request when called from runtime. Full polished chat cards are implemented in the App Product Frontend plan.

- [ ] **Step 7: Verify**

Run:

```bash
swift test --package-path toolkit --filter AttachmentToolTests
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/NativeInteractionBrokerTests
```

Expected: PASS where the platform test runner is available.

---

### Task 6: Capture And System Action Adapters

**Files:**
- Modify: `apps/LocalAgentApp/LocalAgentApp/AppIntents/LocalAgentShortcuts.swift`
- Modify: `apps/LocalAgentApp/LocalAgentApp/AppIntents/AppIntentRouter.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/AppIntents/AgentEntity.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/AppIntents/ConversationEntity.swift`
- Create: `apps/LocalAgentApp/LocalAgentApp/ShareExtension/ShareCaptureIntent.md`
- Test: `apps/LocalAgentApp/LocalAgentAppTests/AppIntents/AppIntentRoutingTests.swift`

**Interfaces:**

```swift
enum AppIntentDestination: Equatable, Sendable {
    case openChat(conversationId: String?)
    case openBuilder(profileId: String?)
    case captureText(text: String, targetAgentProfileId: String?)
}
```

- [ ] **Step 1: Write route tests**

Cover:

- `agent.open_builder` routes to Builder
- `agent.capture_text` creates a capture request and opens Chat or Builder based on selection
- `agent.continue_conversation` routes to a conversation id

- [ ] **Step 2: Run failing tests**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AppIntentRoutingTests
```

Expected: FAIL until entities/routes exist.

- [ ] **Step 3: Add app-owned intents**

Keep the intent surface focused on app-owned actions:

```text
agent.capture_text
agent.start_chat
agent.continue_conversation
agent.open_builder
```

Do not expose arbitrary user Shortcut execution as a model-callable tool.

- [ ] **Step 4: Add Share capture handoff design stub**

Create `ShareCaptureIntent.md` documenting the extension target boundary and payload:

```text
text
url
file attachment ids
target agent/profile if selected
```

The actual Share Extension target can be implemented after App Product Frontend has the route and capture surfaces.

- [ ] **Step 5: Verify**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:LocalAgentAppTests/AppIntentRoutingTests
```

Expected: PASS where the platform test runner is available.

---

### Task 7: Final Verification And Handoff

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Run package verification**

Run:

```bash
swift test --package-path toolkit
```

Expected: PASS.

- [ ] **Step 2: Run app verification**

Run:

```bash
xcodebuild test -project apps/LocalAgentApp/LocalAgentApp.xcodeproj -scheme LocalAgentApp -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS if Xcode and the named simulator are available.

- [ ] **Step 3: Manual smoke**

Run the app and check:

```text
Builder can display native tool cards
Chat can call native.list_tools through NativeToolExecutor
Chat can call web.fetch_url_text and receive untrusted_external_content result
Calendar/reminders tools return missing-permission repair before authorization
After authorization, calendar.search_events and reminders.create_reminder execute
```

- [ ] **Step 4: Update `docs/TODO.md`**

Move completed items out of the active MVP list and keep remaining product work grouped under:

```text
Agent Builder UI
Native Toolkit Real Adapters
App Product Frontend
```

- [ ] **Step 5: Commit**

```bash
git add toolkit apps/LocalAgentApp docs/TODO.md
git commit -m "feat: wire native toolkit real adapters"
```

## Self-Review Checklist

- Every product tool route goes through `NativeToolExecutor`.
- `debug.echo` is development-only and not exported in the production native catalog.
- First real adapters do not present UI from background tools.
- Calendar read and EventKit write-only scopes stay separate.
- User-mediated tools persist pending interaction before system UI.
- File/photo tool results return attachment ids, not raw paths.
- Web fetch denial codes are preserved for audit/UI.
- `reminders.search` remains out of this plan; first reminder tool is `reminders.create_reminder`.
- Full AppShell, Tool Center polish, approval cards, pending interaction cards, and Model Center remain in the App Product Frontend plan.
