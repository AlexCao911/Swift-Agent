# Plan 9: Swift Native Toolkit + Basic Meta Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Swift native toolkit layer that registers basic native/meta tools, executes Rust `ToolExecutionRequestDTO` values, and returns structured `ToolResultDTO` values.

**Architecture:** Rust decides when a tool should run. Swift owns native capability execution through a small `NativeTool` protocol and injected facades for iOS frameworks, so tests can exercise behavior without invoking real calendar, reminders, or shortcuts services.

**Tech Stack:** Swift Package Manager, Swift 5.9, XCTest, Foundation, injectable EventKit/Reminders/Shortcuts facades, DTOs from Plan 8, TDD.

---

## Current Code Audit

Expected after Plan 8:

- `ios-app/Package.swift` exists.
- `LocalAgentBridge` exposes `ToolExecutionRequestDTO` and `ToolResultDTO`.
- `RuntimeClient` is a protocol and `MockRuntimeClient` is available for UI and
  toolkit tests.

Still missing:

- Tool schema DTOs on the Swift side.
- Native tool protocol and catalog.
- Native tool executor.
- Basic meta tools.
- First real read/write native tool boundaries.

Assigned to this plan:

- Add `LocalNativeToolkit` Swift target.
- Add native tool schema/value types.
- Add `NativeToolCatalog`.
- Add meta tools: `native.list_tools` and `native.permission_status`.
- Add injectable facades and tools for calendar search, reminder creation, and
  voice shortcut listing.
- Add `NativeToolExecutor` that returns `ToolResultDTO`.

Deferred:

- Real EventKit permission prompts in app runtime.
- Real `INVoiceShortcutCenter` UI.
- SwiftUI presentation.
- Rust-side automatic schema registration over the bridge.

## File Structure

Create:

```text
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeTool.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolCatalog.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolExecutor.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/PermissionStore.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/MetaTools.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/CalendarTools.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/ReminderTools.swift
local-ios-agent/ios-app/Sources/LocalNativeToolkit/ShortcutTools.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolCatalogTests.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/MetaToolsTests.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift
local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/CalendarReminderShortcutToolTests.swift
```

Modify:

```text
local-ios-agent/ios-app/Package.swift
```

## Task 1: Add Native Tool Protocol and Catalog

**Files:**
- Modify: `local-ios-agent/ios-app/Package.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeTool.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolCatalog.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolCatalogTests.swift`

- [ ] **Step 1: Write failing catalog test**

Create `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolCatalogTests.swift`:

```swift
import XCTest
import LocalAgentBridge
@testable import LocalNativeToolkit

private struct EchoTool: NativeTool {
    let schema = NativeToolSchema(
        name: "debug.echo",
        description: "Echo input text.",
        parametersJsonSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#,
        riskLevel: .readOnly,
        permissionScope: nil
    )

    func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO {
        ToolResultDTO(
            displayText: argumentsJson,
            modelText: argumentsJson,
            structuredJson: argumentsJson,
            auditText: "echo",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }
}

final class NativeToolCatalogTests: XCTestCase {
    func testCatalogRegistersAndListsSchemasInNameOrder() throws {
        var catalog = NativeToolCatalog()
        try catalog.register(EchoTool())

        XCTAssertEqual(catalog.tool(named: "debug.echo")?.schema.name, "debug.echo")
        XCTAssertEqual(catalog.schemas.map(\.name), ["debug.echo"])
    }

    func testCatalogRejectsDuplicateToolNames() throws {
        var catalog = NativeToolCatalog()
        try catalog.register(EchoTool())

        XCTAssertThrowsError(try catalog.register(EchoTool()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter NativeToolCatalogTests
```

Expected: FAIL because `LocalNativeToolkit` does not exist.

- [ ] **Step 3: Add toolkit target and catalog types**

Modify `local-ios-agent/ios-app/Package.swift` so `products` and `targets` are:

```swift
products: [
    .library(name: "LocalAgentBridge", targets: ["LocalAgentBridge"]),
    .library(name: "LocalNativeToolkit", targets: ["LocalNativeToolkit"])
],
targets: [
    .target(name: "LocalAgentBridge"),
    .target(
        name: "LocalNativeToolkit",
        dependencies: ["LocalAgentBridge"]
    ),
    .testTarget(
        name: "LocalAgentBridgeTests",
        dependencies: ["LocalAgentBridge"]
    ),
    .testTarget(
        name: "LocalNativeToolkitTests",
        dependencies: ["LocalNativeToolkit", "LocalAgentBridge"]
    )
]
```

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeTool.swift`:

```swift
import Foundation
import LocalAgentBridge

public enum NativeToolRiskLevel: String, Codable, Equatable, Sendable {
    case readOnly = "read_only"
    case confirm
    case destructive
}

public struct NativeToolSchema: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var parametersJsonSchema: String
    public var riskLevel: NativeToolRiskLevel
    public var permissionScope: String?

    public init(
        name: String,
        description: String,
        parametersJsonSchema: String,
        riskLevel: NativeToolRiskLevel,
        permissionScope: String?
    ) {
        self.name = name
        self.description = description
        self.parametersJsonSchema = parametersJsonSchema
        self.riskLevel = riskLevel
        self.permissionScope = permissionScope
    }
}

public struct NativeToolContext: Sendable {
    public var permissionStore: PermissionStore

    public init(permissionStore: PermissionStore) {
        self.permissionStore = permissionStore
    }
}

public protocol NativeTool: Sendable {
    var schema: NativeToolSchema { get }
    func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO
}

public enum NativeToolCatalogError: Error, Equatable {
    case duplicateTool(String)
    case unknownTool(String)
}
```

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolCatalog.swift`:

```swift
import Foundation

public struct NativeToolCatalog: Sendable {
    private var tools: [String: any NativeTool] = [:]

    public init() {}

    public var schemas: [NativeToolSchema] {
        tools.values.map(\.schema).sorted { $0.name < $1.name }
    }

    public func tool(named name: String) -> (any NativeTool)? {
        tools[name]
    }

    public mutating func register(_ tool: any NativeTool) throws {
        let name = tool.schema.name
        if tools[name] != nil {
            throw NativeToolCatalogError.duplicateTool(name)
        }
        tools[name] = tool
    }
}
```

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/PermissionStore.swift`:

```swift
import Foundation

public enum NativePermissionState: String, Codable, Equatable, Sendable {
    case notDetermined = "not_determined"
    case granted
    case denied
    case restricted
}

public struct PermissionStore: Sendable {
    private var states: [String: NativePermissionState]

    public init(states: [String: NativePermissionState] = [:]) {
        self.states = states
    }

    public func state(for scope: String) -> NativePermissionState {
        states[scope] ?? .notDetermined
    }

    public mutating func set(_ state: NativePermissionState, for scope: String) {
        states[scope] = state
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter NativeToolCatalogTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Package.swift local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeTool.swift local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolCatalog.swift local-ios-agent/ios-app/Sources/LocalNativeToolkit/PermissionStore.swift local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolCatalogTests.swift
git commit -m "feat: add native tool catalog"
```

## Task 2: Add Basic Meta Tools

**Files:**
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/MetaTools.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/MetaToolsTests.swift`

- [ ] **Step 1: Write failing meta tool tests**

Create `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/MetaToolsTests.swift`:

```swift
import XCTest
import LocalAgentBridge
@testable import LocalNativeToolkit

final class MetaToolsTests: XCTestCase {
    func testListToolsReturnsRegisteredSchemas() async throws {
        var catalog = NativeToolCatalog()
        try catalog.register(ListToolsTool(catalogProvider: { catalog.schemas }))

        let result = await catalog.tool(named: "native.list_tools")!.execute(
            argumentsJson: "{}",
            context: NativeToolContext(permissionStore: PermissionStore())
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.modelText.contains("native.list_tools"))
        XCTAssertEqual(result.sensitivity, .public)
    }

    func testPermissionStatusReportsKnownScope() async throws {
        var store = PermissionStore()
        store.set(.granted, for: "calendar.read")
        let tool = PermissionStatusTool()

        let result = await tool.execute(
            argumentsJson: #"{"scope":"calendar.read"}"#,
            context: NativeToolContext(permissionStore: store)
        )

        XCTAssertEqual(result.structuredJson, #"{"scope":"calendar.read","state":"granted"}"#)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter MetaToolsTests
```

Expected: FAIL because meta tools do not exist.

- [ ] **Step 3: Implement meta tools**

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/MetaTools.swift`:

```swift
import Foundation
import LocalAgentBridge

public struct ListToolsTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "native.list_tools",
        description: "List native tools currently registered on this device.",
        parametersJsonSchema: #"{"type":"object","additionalProperties":false}"#,
        riskLevel: .readOnly,
        permissionScope: nil
    )

    private let catalogProvider: @Sendable () -> [NativeToolSchema]

    public init(catalogProvider: @escaping @Sendable () -> [NativeToolSchema]) {
        self.catalogProvider = catalogProvider
    }

    public func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO {
        let schemas = catalogProvider()
        let names = schemas.map(\.name).sorted()
        let structured = #"{"tools":\#(jsonArray(names))}"#
        return ToolResultDTO(
            displayText: names.joined(separator: ", "),
            modelText: "Registered native tools: \(names.joined(separator: ", "))",
            structuredJson: structured,
            auditText: "listed \(names.count) native tools",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }
}

public struct PermissionStatusTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "native.permission_status",
        description: "Report the current state of a native permission scope.",
        parametersJsonSchema: #"{"type":"object","properties":{"scope":{"type":"string"}},"required":["scope"],"additionalProperties":false}"#,
        riskLevel: .readOnly,
        permissionScope: nil
    )

    public init() {}

    public func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO {
        guard
            let data = argumentsJson.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scope = object["scope"] as? String
        else {
            return ToolResultDTO(
                displayText: "Invalid permission status arguments.",
                modelText: "The permission status tool received invalid arguments.",
                structuredJson: #"{"error":"invalid_arguments"}"#,
                auditText: "permission status invalid arguments",
                sensitivity: .public,
                retention: .runOnly,
                isError: true
            )
        }

        let state = context.permissionStore.state(for: scope)
        return ToolResultDTO(
            displayText: "\(scope): \(state.rawValue)",
            modelText: "Permission \(scope) is \(state.rawValue).",
            structuredJson: #"{"scope":"\#(scope)","state":"\#(state.rawValue)"}"#,
            auditText: "checked permission \(scope)",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }
}

private func jsonArray(_ values: [String]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: values)
    return String(data: data, encoding: .utf8)!
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter MetaToolsTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Sources/LocalNativeToolkit/MetaTools.swift local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/MetaToolsTests.swift
git commit -m "feat: add native toolkit meta tools"
```

## Task 3: Add Native Tool Executor

**Files:**
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolExecutor.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift`

- [ ] **Step 1: Write failing executor tests**

Create `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift`:

```swift
import XCTest
import LocalAgentBridge
@testable import LocalNativeToolkit

final class NativeToolExecutorTests: XCTestCase {
    func testExecutorRunsKnownTool() async throws {
        var catalog = NativeToolCatalog()
        try catalog.register(PermissionStatusTool())
        let executor = NativeToolExecutor(catalog: catalog, permissionStore: PermissionStore(states: ["calendar.read": .granted]))

        let result = await executor.execute(
            ToolExecutionRequestDTO(
                runId: "run_1",
                sessionId: "session_1",
                toolCallEntryId: "entry_1",
                toolCallId: "call_1",
                toolName: "native.permission_status",
                argumentsJson: #"{"scope":"calendar.read"}"#
            )
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structuredJson, #"{"scope":"calendar.read","state":"granted"}"#)
    }

    func testExecutorReturnsErrorForUnknownTool() async {
        let executor = NativeToolExecutor(catalog: NativeToolCatalog(), permissionStore: PermissionStore())

        let result = await executor.execute(
            ToolExecutionRequestDTO(
                runId: "run_1",
                sessionId: "session_1",
                toolCallEntryId: "entry_1",
                toolCallId: "call_1",
                toolName: "missing.tool",
                argumentsJson: "{}"
            )
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.modelText.contains("missing.tool"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter NativeToolExecutorTests
```

Expected: FAIL because `NativeToolExecutor` does not exist.

- [ ] **Step 3: Implement executor**

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolExecutor.swift`:

```swift
import Foundation
import LocalAgentBridge

public struct NativeToolExecutor: Sendable {
    private let catalog: NativeToolCatalog
    private let permissionStore: PermissionStore

    public init(catalog: NativeToolCatalog, permissionStore: PermissionStore) {
        self.catalog = catalog
        self.permissionStore = permissionStore
    }

    public func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        guard let tool = catalog.tool(named: request.toolName) else {
            return ToolResultDTO(
                displayText: "Native tool not found.",
                modelText: "Native tool `\(request.toolName)` is not registered.",
                structuredJson: #"{"error":"unknown_tool"}"#,
                auditText: "unknown native tool \(request.toolName)",
                sensitivity: .public,
                retention: .runOnly,
                isError: true
            )
        }

        return await tool.execute(
            argumentsJson: request.argumentsJson,
            context: NativeToolContext(permissionStore: permissionStore)
        )
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter NativeToolExecutorTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Sources/LocalNativeToolkit/NativeToolExecutor.swift local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/NativeToolExecutorTests.swift
git commit -m "feat: add native tool executor"
```

## Task 4: Add Calendar, Reminder, and Shortcut Tool Boundaries

**Files:**
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/CalendarTools.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/ReminderTools.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalNativeToolkit/ShortcutTools.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/CalendarReminderShortcutToolTests.swift`

- [ ] **Step 1: Write failing native boundary tests**

Create `local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/CalendarReminderShortcutToolTests.swift`:

```swift
import XCTest
@testable import LocalNativeToolkit

final class CalendarReminderShortcutToolTests: XCTestCase {
    func testCalendarSearchUsesCalendarFacade() async {
        let tool = CalendarSearchEventsTool(calendar: FakeCalendar(events: [
            CalendarEventSummary(id: "event_1", title: "Design review", startISO8601: "2026-06-18T10:00:00Z")
        ]))

        let result = await tool.execute(argumentsJson: #"{"query":"design"}"#, context: NativeToolContext(permissionStore: PermissionStore()))

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.modelText.contains("Design review"))
        XCTAssertEqual(result.retention, .session)
    }

    func testReminderCreateUsesReminderFacade() async {
        let tool = CreateReminderTool(reminders: FakeReminders(createdId: "reminder_1"))

        let result = await tool.execute(argumentsJson: #"{"title":"Buy milk"}"#, context: NativeToolContext(permissionStore: PermissionStore()))

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.structuredJson.contains("reminder_1"))
        XCTAssertEqual(result.sensitivity, .private)
    }

    func testShortcutListUsesShortcutFacade() async {
        let tool = ListVoiceShortcutsTool(shortcuts: FakeShortcuts(names: ["Morning brief"]))

        let result = await tool.execute(argumentsJson: "{}", context: NativeToolContext(permissionStore: PermissionStore()))

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.modelText.contains("Morning brief"))
    }
}

private struct FakeCalendar: CalendarReading {
    let events: [CalendarEventSummary]
    func searchEvents(query: String) async throws -> [CalendarEventSummary] { events }
}

private struct FakeReminders: ReminderWriting {
    let createdId: String
    func createReminder(title: String, notes: String?) async throws -> String { createdId }
}

private struct FakeShortcuts: VoiceShortcutListing {
    let names: [String]
    func listVoiceShortcutNames() async throws -> [String] { names }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter CalendarReminderShortcutToolTests
```

Expected: FAIL because native boundary tools do not exist.

- [ ] **Step 3: Implement calendar tool**

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/CalendarTools.swift`:

```swift
import Foundation
import LocalAgentBridge

public struct CalendarEventSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startISO8601: String

    public init(id: String, title: String, startISO8601: String) {
        self.id = id
        self.title = title
        self.startISO8601 = startISO8601
    }
}

public protocol CalendarReading: Sendable {
    func searchEvents(query: String) async throws -> [CalendarEventSummary]
}

public struct CalendarSearchEventsTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "calendar.search_events",
        description: "Search calendar events by text.",
        parametersJsonSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
        riskLevel: .readOnly,
        permissionScope: "calendar.read"
    )

    private let calendar: CalendarReading

    public init(calendar: CalendarReading) {
        self.calendar = calendar
    }

    public func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO {
        guard let query = stringArgument("query", in: argumentsJson) else {
            return nativeArgumentError(tool: schema.name)
        }

        do {
            let events = try await calendar.searchEvents(query: query)
            let titles = events.map { "\($0.title) at \($0.startISO8601)" }
            let data = try JSONEncoder.localAgent.encode(events)
            return ToolResultDTO(
                displayText: titles.joined(separator: "\n"),
                modelText: titles.isEmpty ? "No matching calendar events." : "Matching calendar events: \(titles.joined(separator: "; "))",
                structuredJson: String(data: data, encoding: .utf8)!,
                auditText: "searched calendar events for \(query)",
                sensitivity: .private,
                retention: .session,
                isError: false
            )
        } catch {
            return nativeExecutionError(tool: schema.name, error: error)
        }
    }
}
```

- [ ] **Step 4: Implement reminder and shortcut tools**

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/ReminderTools.swift`:

```swift
import Foundation
import LocalAgentBridge

public protocol ReminderWriting: Sendable {
    func createReminder(title: String, notes: String?) async throws -> String
}

public struct CreateReminderTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "reminders.create_reminder",
        description: "Create a reminder after user confirmation.",
        parametersJsonSchema: #"{"type":"object","properties":{"title":{"type":"string"},"notes":{"type":"string"}},"required":["title"],"additionalProperties":false}"#,
        riskLevel: .confirm,
        permissionScope: "reminders.write"
    )

    private let reminders: ReminderWriting

    public init(reminders: ReminderWriting) {
        self.reminders = reminders
    }

    public func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO {
        guard let title = stringArgument("title", in: argumentsJson) else {
            return nativeArgumentError(tool: schema.name)
        }
        let notes = stringArgument("notes", in: argumentsJson)

        do {
            let id = try await reminders.createReminder(title: title, notes: notes)
            return ToolResultDTO(
                displayText: "Created reminder: \(title)",
                modelText: "Reminder created: \(title)",
                structuredJson: #"{"id":"\#(id)","title":"\#(title)"}"#,
                auditText: "created reminder \(id)",
                sensitivity: .private,
                retention: .session,
                isError: false
            )
        } catch {
            return nativeExecutionError(tool: schema.name, error: error)
        }
    }
}
```

Create `local-ios-agent/ios-app/Sources/LocalNativeToolkit/ShortcutTools.swift`:

```swift
import Foundation
import LocalAgentBridge

public protocol VoiceShortcutListing: Sendable {
    func listVoiceShortcutNames() async throws -> [String]
}

public struct ListVoiceShortcutsTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "shortcuts.list_voice_shortcuts",
        description: "List donated voice shortcut names.",
        parametersJsonSchema: #"{"type":"object","additionalProperties":false}"#,
        riskLevel: .readOnly,
        permissionScope: "shortcuts.read"
    )

    private let shortcuts: VoiceShortcutListing

    public init(shortcuts: VoiceShortcutListing) {
        self.shortcuts = shortcuts
    }

    public func execute(argumentsJson: String, context: NativeToolContext) async -> ToolResultDTO {
        do {
            let names = try await shortcuts.listVoiceShortcutNames()
            return ToolResultDTO(
                displayText: names.joined(separator: ", "),
                modelText: names.isEmpty ? "No voice shortcuts are registered." : "Voice shortcuts: \(names.joined(separator: ", "))",
                structuredJson: #"{"names":\#(jsonArray(names))}"#,
                auditText: "listed \(names.count) voice shortcuts",
                sensitivity: .public,
                retention: .runOnly,
                isError: false
            )
        } catch {
            return nativeExecutionError(tool: schema.name, error: error)
        }
    }
}

func stringArgument(_ key: String, in argumentsJson: String) -> String? {
    guard
        let data = argumentsJson.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object[key] as? String
}

func nativeArgumentError(tool: String) -> ToolResultDTO {
    ToolResultDTO(
        displayText: "Invalid tool arguments.",
        modelText: "Native tool `\(tool)` received invalid arguments.",
        structuredJson: #"{"error":"invalid_arguments"}"#,
        auditText: "\(tool) invalid arguments",
        sensitivity: .public,
        retention: .runOnly,
        isError: true
    )
}

func nativeExecutionError(tool: String, error: Error) -> ToolResultDTO {
    ToolResultDTO(
        displayText: "Native tool failed.",
        modelText: "Native tool `\(tool)` failed: \(error.localizedDescription)",
        structuredJson: #"{"error":"execution_failed"}"#,
        auditText: "\(tool) failed: \(error.localizedDescription)",
        sensitivity: .public,
        retention: .runOnly,
        isError: true
    )
}
```

- [ ] **Step 5: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Sources/LocalNativeToolkit/CalendarTools.swift local-ios-agent/ios-app/Sources/LocalNativeToolkit/ReminderTools.swift local-ios-agent/ios-app/Sources/LocalNativeToolkit/ShortcutTools.swift local-ios-agent/ios-app/Tests/LocalNativeToolkitTests/CalendarReminderShortcutToolTests.swift
git commit -m "feat: add first native toolkit tools"
```

## Self-Review

Spec coverage:

- Meta tools cover tool discovery and permission status.
- `calendar.search_events` is the first read tool.
- `reminders.create_reminder` is the first confirmation-level write tool.
- `shortcuts.list_voice_shortcuts` establishes the Shortcuts read boundary.
- `NativeToolExecutor` consumes Rust bridge requests and emits Rust bridge tool
  results.

Placeholder scan:

- No placeholder terms are used as implementation instructions.

Type consistency:

- `ToolExecutionRequestDTO.toolName` maps directly to `NativeToolSchema.name`.
- Every tool returns `ToolResultDTO` with sensitivity, retention, and audit text.
