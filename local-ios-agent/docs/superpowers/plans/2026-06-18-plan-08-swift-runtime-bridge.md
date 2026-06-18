# Plan 8: Swift Runtime Bridge Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first testable Swift-facing runtime bridge: Swift DTOs, a runtime client protocol, a deterministic mock client, and a Rust JSON bridge over the existing mock runtime.

**Architecture:** Swift receives typed DTOs and calls a `RuntimeClient` protocol. Rust remains the source of runtime truth and exposes a narrow JSON bridge that can later be replaced by generated UniFFI bindings without changing the Swift toolkit or SwiftUI call sites.

**Tech Stack:** Swift Package Manager, Swift 5.9, XCTest, Rust 2021, existing `AgentRuntime`, existing `MockStreamingProvider`, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
rg --files local-ios-agent -g '!**/target/**'
sed -n '1,220p' local-ios-agent/rust-core/src/core/runtime.rs
sed -n '1,180p' local-ios-agent/rust-core/src/tool/execution_request.rs
sed -n '1,120p' local-ios-agent/rust-core/src/security/approval_protocol.rs
```

Observed:

- `rust-core` has a complete in-process mock runtime path with
  `AgentRuntime`, `SendMessageInput`, `AgentTurnResult`, `RuntimeEvent`, and
  `MockStreamingProvider`.
- Rust exposes pending tool and pending approval request accessors, but no
  Swift-callable bridge exists.
- There is no `ios-app` directory or Swift Package.
- Existing Rust DTOs use strong Rust types (`SessionId`, `RunId`, `EntryId`)
  that should be flattened for Swift.

Assigned to this plan:

- Create `ios-app` Swift package.
- Define Swift DTOs for runtime events, turn results, tool execution requests,
  approval requests/responses, and tool results.
- Add a `RuntimeClient` protocol and deterministic `MockRuntimeClient`.
- Add a safe Rust `RuntimeJsonBridge` and C-string wrapper functions for the
  mock runtime.
- Add fixture tests so Rust bridge JSON decodes into Swift DTOs.

Deferred:

- Real generated UniFFI scaffolding.
- SwiftUI views.
- Native iOS tool implementations.
- Desktop MiniCPM provider.

## File Structure

Create:

```text
local-ios-agent/ios-app/Package.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeDTOs.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeClient.swift
local-ios-agent/ios-app/Sources/LocalAgentBridge/MockRuntimeClient.swift
local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift
local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/MockRuntimeClientTests.swift
local-ios-agent/rust-core/src/ffi_bridge.rs
local-ios-agent/rust-core/tests/ffi_bridge.rs
```

Modify:

```text
local-ios-agent/rust-core/src/lib.rs
local-ios-agent/rust-core/Cargo.toml
```

## Task 1: Create Swift Package and Runtime DTOs

**Files:**
- Create: `local-ios-agent/ios-app/Package.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeDTOs.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift`

- [ ] **Step 1: Write the failing DTO decode test**

Create `local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift`:

```swift
import XCTest
@testable import LocalAgentBridge

final class RuntimeDTOTests: XCTestCase {
    func testTurnResultDecodesRustBridgeJSON() throws {
        let json = """
        {
          "run_id": "run_1",
          "state": "completed",
          "pending_tool_call_id": null,
          "events": [
            {
              "id": "entry_1",
              "session_id": "session_1",
              "parent_id": null,
              "run_id": "run_1",
              "sequence": 1,
              "depth": 0,
              "kind": "AssistantMessageCompleted",
              "payload": "hello",
              "blob_refs": []
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder.localAgent.decode(AgentTurnResultDTO.self, from: json)

        XCTAssertEqual(result.runId, "run_1")
        XCTAssertEqual(result.state, .completed)
        XCTAssertNil(result.pendingToolCallId)
        XCTAssertEqual(result.events.first?.kind, .assistantMessageCompleted)
        XCTAssertEqual(result.events.first?.payload, "hello")
    }

    func testToolResultEncodesSnakeCaseForRust() throws {
        let result = ToolResultDTO(
            displayText: "Created reminder",
            modelText: "Reminder created",
            structuredJson: #"{"id":"reminder_1"}"#,
            auditText: "created reminder_1",
            sensitivity: .private,
            retention: .session,
            isError: false
        )

        let data = try JSONEncoder.localAgent.encode(result)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(object["display_text"] as? String, "Created reminder")
        XCTAssertEqual(object["model_text"] as? String, "Reminder created")
        XCTAssertEqual(object["structured_json"] as? String, #"{"id":"reminder_1"}"#)
        XCTAssertEqual(object["audit_text"] as? String, "created reminder_1")
        XCTAssertEqual(object["sensitivity"] as? String, "private")
        XCTAssertEqual(object["retention"] as? String, "session")
        XCTAssertEqual(object["is_error"] as? Bool, false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter RuntimeDTOTests
```

Expected: FAIL because `Package.swift` and `LocalAgentBridge` do not exist.

- [ ] **Step 3: Create package and DTO implementation**

Create `local-ios-agent/ios-app/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalIOSAgent",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LocalAgentBridge", targets: ["LocalAgentBridge"])
    ],
    targets: [
        .target(name: "LocalAgentBridge"),
        .testTarget(
            name: "LocalAgentBridgeTests",
            dependencies: ["LocalAgentBridge"]
        )
    ]
)
```

Create `local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeDTOs.swift`:

```swift
import Foundation

public extension JSONDecoder {
    static var localAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

public extension JSONEncoder {
    static var localAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public enum RuntimeEventKindDTO: String, Codable, Equatable {
    case sessionCreated = "SessionCreated"
    case providerChanged = "ProviderChanged"
    case toolRegistered = "ToolRegistered"
    case userMessage = "UserMessage"
    case assistantMessageStarted = "AssistantMessageStarted"
    case assistantTextDelta = "AssistantTextDelta"
    case assistantMessageCompleted = "AssistantMessageCompleted"
    case toolCallRequested = "ToolCallRequested"
    case toolCallApproved = "ToolCallApproved"
    case toolCallRejected = "ToolCallRejected"
    case toolExecutionStarted = "ToolExecutionStarted"
    case toolExecutionUpdate = "ToolExecutionUpdate"
    case toolExecutionCompleted = "ToolExecutionCompleted"
    case toolExecutionFailed = "ToolExecutionFailed"
    case toolResultMessage = "ToolResultMessage"
    case runSuspended = "RunSuspended"
    case runResumed = "RunResumed"
    case compactionCreated = "CompactionCreated"
    case branchSummaryCreated = "BranchSummaryCreated"
    case runCancelled = "RunCancelled"
    case runFailed = "RunFailed"
}

public struct RuntimeEventDTO: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var parentId: String?
    public var runId: String?
    public var sequence: UInt64
    public var depth: UInt32
    public var kind: RuntimeEventKindDTO
    public var payload: String
    public var blobRefs: [String]

    public init(
        id: String,
        sessionId: String,
        parentId: String?,
        runId: String?,
        sequence: UInt64,
        depth: UInt32,
        kind: RuntimeEventKindDTO,
        payload: String,
        blobRefs: [String]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.runId = runId
        self.sequence = sequence
        self.depth = depth
        self.kind = kind
        self.payload = payload
        self.blobRefs = blobRefs
    }
}

public enum RunStateDTO: String, Codable, Equatable, Sendable {
    case running
    case waitingTool = "waiting_tool"
    case suspended
    case failed
    case cancelled
    case completed
}

public struct AgentTurnResultDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var state: RunStateDTO
    public var events: [RuntimeEventDTO]
    public var pendingToolCallId: String?

    public init(
        runId: String,
        state: RunStateDTO,
        events: [RuntimeEventDTO],
        pendingToolCallId: String?
    ) {
        self.runId = runId
        self.state = state
        self.events = events
        self.pendingToolCallId = pendingToolCallId
    }
}

public struct ToolExecutionRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var sessionId: String
    public var toolCallEntryId: String
    public var toolCallId: String
    public var toolName: String
    public var argumentsJson: String

    public init(
        runId: String,
        sessionId: String,
        toolCallEntryId: String,
        toolCallId: String,
        toolName: String,
        argumentsJson: String
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.toolCallEntryId = toolCallEntryId
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.argumentsJson = argumentsJson
    }
}

public struct ApprovalProtocolRequestDTO: Codable, Equatable, Sendable {
    public var approvalId: String
    public var message: String
    public var requiresLocalAuthentication: Bool
}

public struct ApprovalProtocolResponseDTO: Codable, Equatable, Sendable {
    public var approvalId: String
    public var approved: Bool
}

public enum SensitivityDTO: String, Codable, Equatable, Sendable {
    case `public`
    case `private`
    case secret
}

public enum RetentionPolicyDTO: String, Codable, Equatable, Sendable {
    case runOnly = "run_only"
    case session
    case memoryCandidate = "memory_candidate"
    case auditOnly = "audit_only"
}

public struct ToolResultDTO: Codable, Equatable, Sendable {
    public var displayText: String
    public var modelText: String
    public var structuredJson: String
    public var auditText: String
    public var sensitivity: SensitivityDTO
    public var retention: RetentionPolicyDTO
    public var isError: Bool

    public init(
        displayText: String,
        modelText: String,
        structuredJson: String,
        auditText: String,
        sensitivity: SensitivityDTO,
        retention: RetentionPolicyDTO,
        isError: Bool
    ) {
        self.displayText = displayText
        self.modelText = modelText
        self.structuredJson = structuredJson
        self.auditText = auditText
        self.sensitivity = sensitivity
        self.retention = retention
        self.isError = isError
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter RuntimeDTOTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Package.swift local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeDTOs.swift local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift
git commit -m "feat: add Swift runtime bridge DTOs"
```

## Task 2: Add Runtime Client Protocol and Mock Client

**Files:**
- Create: `local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeClient.swift`
- Create: `local-ios-agent/ios-app/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Create: `local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/MockRuntimeClientTests.swift`

- [ ] **Step 1: Write failing mock client test**

Create `local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/MockRuntimeClientTests.swift`:

```swift
import XCTest
@testable import LocalAgentBridge

final class MockRuntimeClientTests: XCTestCase {
    func testMockRuntimeClientCreatesSessionAndSendsMessage() async throws {
        let client = MockRuntimeClient()

        let sessionId = try await client.createSession()
        let turn = try await client.sendMessage(
            sessionId: sessionId,
            parentEventId: nil,
            text: "hello"
        )

        XCTAssertEqual(sessionId, "session_1")
        XCTAssertEqual(turn.runId, "run_1")
        XCTAssertEqual(turn.state, .completed)
        XCTAssertEqual(turn.events.map(\.kind), [
            .userMessage,
            .assistantMessageStarted,
            .assistantTextDelta,
            .assistantMessageCompleted
        ])
        XCTAssertEqual(turn.events.last?.payload, "Mock response to: hello")
    }

    func testMockRuntimeClientSurfacesToolRequest() async throws {
        let client = MockRuntimeClient()

        let sessionId = try await client.createSession()
        let turn = try await client.sendMessage(
            sessionId: sessionId,
            parentEventId: nil,
            text: "use tool debug.echo"
        )

        XCTAssertEqual(turn.state, .waitingTool)
        XCTAssertEqual(turn.pendingToolCallId, "call_mock_1")
        XCTAssertEqual(try await client.pendingToolRequests().first?.toolName, "debug.echo")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test --filter MockRuntimeClientTests
```

Expected: FAIL because `RuntimeClient` and `MockRuntimeClient` do not exist.

- [ ] **Step 3: Implement client protocol and mock client**

Create `local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeClient.swift`:

```swift
import Foundation

public protocol RuntimeClient: Sendable {
    func createSession() async throws -> String
    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO
    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO]
    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO]
    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO
    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO
    func cancel(runId: String) async throws -> RuntimeEventDTO
}
```

Create `local-ios-agent/ios-app/Sources/LocalAgentBridge/MockRuntimeClient.swift`:

```swift
import Foundation

public actor MockRuntimeClient: RuntimeClient {
    private var nextSession = 1
    private var nextRun = 1
    private var nextEntry = 1
    private var pendingTools: [ToolExecutionRequestDTO] = []

    public init() {}

    public func createSession() async throws -> String {
        let sessionId = "session_\(nextSession)"
        nextSession += 1
        return sessionId
    }

    public func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) async throws -> AgentTurnResultDTO {
        let runId = "run_\(nextRun)"
        nextRun += 1

        let user = event(sessionId: sessionId, parentId: parentEventId, runId: runId, kind: .userMessage, payload: text)
        let start = event(sessionId: sessionId, parentId: user.id, runId: runId, kind: .assistantMessageStarted, payload: "run \(runId)")

        if text == "use tool debug.echo" {
            let requestEvent = event(
                sessionId: sessionId,
                parentId: start.id,
                runId: runId,
                kind: .toolCallRequested,
                payload: #"{"id":"call_mock_1","name":"debug.echo","arguments_json":"{\"text\":\"hello\"}"}"#
            )
            pendingTools = [
                ToolExecutionRequestDTO(
                    runId: runId,
                    sessionId: sessionId,
                    toolCallEntryId: requestEvent.id,
                    toolCallId: "call_mock_1",
                    toolName: "debug.echo",
                    argumentsJson: #"{"text":"hello"}"#
                )
            ]
            return AgentTurnResultDTO(
                runId: runId,
                state: .waitingTool,
                events: [user, start, requestEvent],
                pendingToolCallId: "call_mock_1"
            )
        }

        let delta = event(sessionId: sessionId, parentId: start.id, runId: runId, kind: .assistantTextDelta, payload: "Mock response to: \(text)")
        let complete = event(sessionId: sessionId, parentId: delta.id, runId: runId, kind: .assistantMessageCompleted, payload: "Mock response to: \(text)")
        return AgentTurnResultDTO(
            runId: runId,
            state: .completed,
            events: [user, start, delta, complete],
            pendingToolCallId: nil
        )
    }

    public func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        pendingTools
    }

    public func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    public func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        pendingTools.removeAll()
        let event = RuntimeEventDTO(
            id: "entry_\(nextEntry)",
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: UInt64(nextEntry),
            depth: 0,
            kind: .assistantMessageCompleted,
            payload: "Mock response after tool: \(result.modelText)",
            blobRefs: []
        )
        nextEntry += 1
        return AgentTurnResultDTO(runId: runId, state: .completed, events: [event], pendingToolCallId: nil)
    }

    public func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        AgentTurnResultDTO(runId: "run_1", state: .completed, events: [], pendingToolCallId: nil)
    }

    public func cancel(runId: String) async throws -> RuntimeEventDTO {
        event(sessionId: "session_1", parentId: nil, runId: runId, kind: .runCancelled, payload: "run \(runId) cancelled")
    }

    private func event(
        sessionId: String,
        parentId: String?,
        runId: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        let entryId = "entry_\(nextEntry)"
        let sequence = nextEntry
        nextEntry += 1
        return RuntimeEventDTO(
            id: entryId,
            sessionId: sessionId,
            parentId: parentId,
            runId: runId,
            sequence: UInt64(sequence),
            depth: UInt32(max(0, sequence - 1)),
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/ios-app
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/ios-app/Sources/LocalAgentBridge/RuntimeClient.swift local-ios-agent/ios-app/Sources/LocalAgentBridge/MockRuntimeClient.swift local-ios-agent/ios-app/Tests/LocalAgentBridgeTests/MockRuntimeClientTests.swift
git commit -m "feat: add Swift runtime client protocol"
```

## Task 3: Add Safe Rust Runtime JSON Bridge

**Files:**
- Create: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Create: `local-ios-agent/rust-core/tests/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/src/lib.rs`

- [ ] **Step 1: Write failing Rust bridge test**

Create `local-ios-agent/rust-core/tests/ffi_bridge.rs`:

```rust
use local_ios_agent_runtime::ffi_bridge::RuntimeJsonBridge;
use serde_json::Value;

#[test]
fn runtime_json_bridge_sends_message_as_snake_case_json() {
    let mut bridge = RuntimeJsonBridge::mock();
    let session = bridge.create_session_json().unwrap();
    let session_id = serde_json::from_str::<Value>(&session).unwrap()["session_id"]
        .as_str()
        .unwrap()
        .to_string();

    let turn = bridge
        .send_message_json(&session_id, None, "hello from ffi")
        .unwrap();
    let value: Value = serde_json::from_str(&turn).unwrap();

    assert_eq!(value["run_id"].as_str(), Some("run_1"));
    assert_eq!(value["state"].as_str(), Some("completed"));
    assert_eq!(
        value["events"].as_array().unwrap().last().unwrap()["kind"].as_str(),
        Some("AssistantMessageCompleted")
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test ffi_bridge runtime_json_bridge_sends_message_as_snake_case_json
```

Expected: FAIL because `ffi_bridge` does not exist.

- [ ] **Step 3: Implement safe JSON bridge**

Create `local-ios-agent/rust-core/src/ffi_bridge.rs`:

```rust
use serde_json::{json, Value};

use crate::context::MockTokenizer;
use crate::core::{
    AgentRuntime, AgentRuntimeConfig, AgentTurnResult, EventKind, MockStreamingProvider,
    RuntimeEvent, SendMessageInput,
};
use crate::memory::InMemoryEventStore;

pub struct RuntimeJsonBridge {
    runtime: AgentRuntime<InMemoryEventStore>,
}

impl RuntimeJsonBridge {
    pub fn mock() -> Self {
        let config = AgentRuntimeConfig {
            system_prompt: "You are a local-first assistant.".into(),
            runtime_policy: "Use tools for system actions.".into(),
            tool_schemas: Vec::new(),
            tokenizer: Box::new(MockTokenizer::new(2048)),
            provider: Box::new(MockStreamingProvider::new()),
            tool_router: None,
        };
        Self {
            runtime: AgentRuntime::new(config),
        }
    }

    pub fn create_session_json(&mut self) -> Result<String, String> {
        self.runtime
            .create_session()
            .map(|session_id| json!({ "session_id": session_id.0 }).to_string())
            .map_err(|error| error.to_string())
    }

    pub fn send_message_json(
        &mut self,
        session_id: &str,
        parent_event_id: Option<&str>,
        text: &str,
    ) -> Result<String, String> {
        self.runtime
            .send_message_turn(SendMessageInput {
                session_id: crate::core::SessionId(session_id.to_string()),
                parent_event_id: parent_event_id.map(|value| crate::core::EntryId(value.to_string())),
                text: text.to_string(),
            })
            .map(turn_result_json)
            .map(|value| value.to_string())
            .map_err(|error| error.to_string())
    }
}

fn turn_result_json(turn: AgentTurnResult) -> Value {
    json!({
        "run_id": turn.run_id,
        "state": run_state_json(&turn.state),
        "events": turn.events.into_iter().map(runtime_event_json).collect::<Vec<_>>(),
        "pending_tool_call_id": turn.pending_tool_call_id,
    })
}

fn runtime_event_json(event: RuntimeEvent) -> Value {
    json!({
        "id": event.id.0,
        "session_id": event.session_id.0,
        "parent_id": event.parent_id.map(|id| id.0),
        "run_id": event.run_id.map(|id| id.0),
        "sequence": event.sequence,
        "depth": event.depth,
        "kind": event_kind_json(&event.kind),
        "payload": event.payload,
        "blob_refs": event.blob_refs,
    })
}

fn run_state_json(state: &crate::core::RunState) -> &'static str {
    match state {
        crate::core::RunState::Running => "running",
        crate::core::RunState::WaitingTool => "waiting_tool",
        crate::core::RunState::Suspended => "suspended",
        crate::core::RunState::Failed => "failed",
        crate::core::RunState::Cancelled => "cancelled",
        crate::core::RunState::Completed => "completed",
    }
}

fn event_kind_json(kind: &EventKind) -> &'static str {
    match kind {
        EventKind::SessionCreated => "SessionCreated",
        EventKind::ProviderChanged => "ProviderChanged",
        EventKind::ToolRegistered => "ToolRegistered",
        EventKind::UserMessage => "UserMessage",
        EventKind::AssistantMessageStarted => "AssistantMessageStarted",
        EventKind::AssistantTextDelta => "AssistantTextDelta",
        EventKind::AssistantMessageCompleted => "AssistantMessageCompleted",
        EventKind::ToolCallRequested => "ToolCallRequested",
        EventKind::ToolCallApproved => "ToolCallApproved",
        EventKind::ToolCallRejected => "ToolCallRejected",
        EventKind::ToolExecutionStarted => "ToolExecutionStarted",
        EventKind::ToolExecutionUpdate => "ToolExecutionUpdate",
        EventKind::ToolExecutionCompleted => "ToolExecutionCompleted",
        EventKind::ToolExecutionFailed => "ToolExecutionFailed",
        EventKind::ToolResultMessage => "ToolResultMessage",
        EventKind::RunSuspended => "RunSuspended",
        EventKind::RunResumed => "RunResumed",
        EventKind::CompactionCreated => "CompactionCreated",
        EventKind::BranchSummaryCreated => "BranchSummaryCreated",
        EventKind::RunCancelled => "RunCancelled",
        EventKind::RunFailed => "RunFailed",
    }
}
```

Modify `local-ios-agent/rust-core/src/lib.rs`:

```rust
pub mod context;
pub mod core;
pub mod ffi_bridge;
pub mod memory;
pub mod security;
pub mod tool;
pub mod utils;
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test ffi_bridge runtime_json_bridge_sends_message_as_snake_case_json
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/ffi_bridge.rs local-ios-agent/rust-core/src/lib.rs local-ios-agent/rust-core/tests/ffi_bridge.rs
git commit -m "feat: add runtime JSON bridge"
```

## Task 4: Add C-Compatible Bridge Wrapper

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/Cargo.toml`
- Modify: `local-ios-agent/rust-core/tests/ffi_bridge.rs`

- [ ] **Step 1: Add failing C wrapper test**

Append to `local-ios-agent/rust-core/tests/ffi_bridge.rs`:

```rust
use std::ffi::{CStr, CString};

use local_ios_agent_runtime::ffi_bridge::{
    lia_runtime_create_mock, lia_runtime_create_session, lia_runtime_free,
    lia_runtime_send_message, lia_string_free,
};

#[test]
fn c_wrapper_returns_owned_json_strings() {
    unsafe {
        let handle = lia_runtime_create_mock();
        assert!(!handle.is_null());

        let session_json = lia_runtime_create_session(handle);
        assert!(!session_json.is_null());
        let session = CStr::from_ptr(session_json).to_string_lossy().to_string();
        lia_string_free(session_json);

        let session_id = serde_json::from_str::<Value>(&session).unwrap()["session_id"]
            .as_str()
            .unwrap()
            .to_string();
        let session_id = CString::new(session_id).unwrap();
        let text = CString::new("hello c").unwrap();

        let turn_json = lia_runtime_send_message(handle, session_id.as_ptr(), std::ptr::null(), text.as_ptr());
        assert!(!turn_json.is_null());
        let turn = CStr::from_ptr(turn_json).to_string_lossy().to_string();
        lia_string_free(turn_json);
        lia_runtime_free(handle);

        assert_eq!(serde_json::from_str::<Value>(&turn).unwrap()["state"], "completed");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test ffi_bridge c_wrapper_returns_owned_json_strings
```

Expected: FAIL because C wrapper functions do not exist.

- [ ] **Step 3: Implement C wrapper and crate type**

Append to `local-ios-agent/rust-core/src/ffi_bridge.rs`:

```rust
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn lia_runtime_create_mock() -> *mut RuntimeJsonBridge {
    Box::into_raw(Box::new(RuntimeJsonBridge::mock()))
}

#[no_mangle]
pub unsafe extern "C" fn lia_runtime_free(handle: *mut RuntimeJsonBridge) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lia_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub unsafe extern "C" fn lia_runtime_create_session(handle: *mut RuntimeJsonBridge) -> *mut c_char {
    let Some(bridge) = handle.as_mut() else {
        return owned_string(r#"{"error":"runtime handle is null"}"#);
    };
    owned_result(bridge.create_session_json())
}

#[no_mangle]
pub unsafe extern "C" fn lia_runtime_send_message(
    handle: *mut RuntimeJsonBridge,
    session_id: *const c_char,
    parent_event_id: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    let Some(bridge) = handle.as_mut() else {
        return owned_string(r#"{"error":"runtime handle is null"}"#);
    };
    let Some(session_id) = read_c_string(session_id) else {
        return owned_string(r#"{"error":"session_id is null"}"#);
    };
    let Some(text) = read_c_string(text) else {
        return owned_string(r#"{"error":"text is null"}"#);
    };
    let parent = if parent_event_id.is_null() {
        None
    } else {
        read_c_string(parent_event_id)
    };

    owned_result(bridge.send_message_json(&session_id, parent.as_deref(), &text))
}

unsafe fn read_c_string(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }
    CStr::from_ptr(value).to_str().ok().map(str::to_string)
}

fn owned_result(result: Result<String, String>) -> *mut c_char {
    match result {
        Ok(value) => owned_string(&value),
        Err(error) => owned_string(&json!({ "error": error }).to_string()),
    }
}

fn owned_string(value: &str) -> *mut c_char {
    CString::new(value).unwrap_or_else(|_| CString::new(r#"{"error":"invalid string"}"#).unwrap()).into_raw()
}
```

Modify `local-ios-agent/rust-core/Cargo.toml`:

```toml
[lib]
name = "local_ios_agent_runtime"
path = "src/lib.rs"
crate-type = ["rlib", "staticlib", "cdylib"]
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test ffi_bridge
cargo test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/Cargo.toml local-ios-agent/rust-core/src/ffi_bridge.rs local-ios-agent/rust-core/tests/ffi_bridge.rs
git commit -m "feat: expose runtime C bridge"
```

## Self-Review

Spec coverage:

- Swift DTOs cover runtime events, turn results, tool execution requests,
  approval protocol, and tool results.
- `RuntimeClient` gives Swift toolkit and SwiftUI a stable seam.
- Rust bridge uses existing mock runtime and returns Swift-decodable JSON.

Placeholder scan:

- No placeholder terms are used as implementation instructions.

Type consistency:

- `run_id`, `session_id`, `parent_id`, `pending_tool_call_id`, and
  `arguments_json` match the Rust bridge JSON and Swift DTO keys.
