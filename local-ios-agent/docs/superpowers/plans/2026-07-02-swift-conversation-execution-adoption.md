# Swift Conversation Execution Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adapt the Swift app to the new Rust `conversation -> execution` contract while keeping the existing chat UI operational during migration.

**Architecture:** Add a narrow bridge layer over JSON over C ABI, then expose two app domains: `ConversationDomain` prepares and commits conversation turns; `ExecutionDomain` starts and observes runs through focused services. `ChatInteractionCoordinator` connects the two domains for the send-message workflow. Current `AgentRuntimeService` and `AgentViewModel` remain as compatibility facades until the new path is fully wired.

**Tech Stack:** Swift `LocalAgentBridge` package, SwiftUI app target `LocalAgentApp`, XCTest, existing Rust JSON over C ABI.

## Global Constraints

- Swift execution start must pass `ConversationRunFrameRefDTO`; it must not pass a full `ConversationRunFrameDTO` as trusted execution input.
- Full `ConversationRunFrameDTO` is allowed only for UI projection, preview, and debug inspection.
- `observeEvents(runId:fromSequence:)` must consume a Rust event stream that replays durable events before tailing live events.
- `commitAssistantResult` must be idempotent from Swift's perspective; coordinator retry is allowed and expected.
- `ExecutionDomain` and `ExecutionService` must stay facades over focused services. Agent composition, run lifecycle, event observation, tool approval, debug, and inference settings must not collapse into one implementation object.
- UI redesign is outside this plan. The work here is contract, state, and orchestration wiring.
- Rust contract work from `2026-07-02-rust-kernel-conversation-execution-migration.md` lands first or is represented by mocks during Swift development.

---

## Adoption Shape

The Swift migration follows the Rust migration without forcing an immediate UI rewrite:

```text
Stage 1: Toolkit DTO contract
  ConversationRunFrameRefDTO
  PreparedUserTurnDTO
  StartExecutionRequestDTO
  RunHandleDTO.replayFromSequence
  ExecutionEventDTO sequence guarantees

Stage 2: Bridge split over one Rust runtime handle
  RustAgentOSBridgeGateway
  ConversationBridgeClient
  ExecutionBridgeClient
  existing RustRuntimeClient delegates for compatibility

Stage 3: App domain split
  ConversationDomain facade over conversation bridge operations
  ExecutionDomain facade over focused execution services

Stage 4: Coordinator path
  prepareUserTurn -> startRun -> observeEvents -> commitAssistantResult
  recovery pass for completed-but-uncommitted runs

Stage 5: Compatibility routing
  AgentRuntimeService remains available
  new send-message path is introduced behind an injectable coordinator
  old sendMessageStream path is classified as legacy compatibility
```

## File Structure

Create in toolkit:

- `toolkit/Sources/LocalAgentBridge/ConversationBridgeClient.swift`
- `toolkit/Sources/LocalAgentBridge/ExecutionBridgeClient.swift`
- `toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`

Modify in toolkit:

- `toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- `toolkit/Sources/LocalAgentBridge/RuntimeClient.swift`
- `toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- `toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- `toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift`
- `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`
- `toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientStreamingTests.swift`

Create in app:

- `apps/LocalAgentApp/LocalAgentApp/Runtime/Conversation/ConversationDomain.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Conversation/ConversationDomainAdapter.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ExecutionDomain.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ExecutionDomainAdapter.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/AgentProfileService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/AgentCompositionService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/RunLifecycleService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/RunEventStreamService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ToolApprovalService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/RunDebugService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/InferenceSettingsService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift`
- `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationViewModel.swift`
- `apps/LocalAgentApp/LocalAgentApp/Presentation/Runtime/AgentRunViewModel.swift`

Modify in app:

- `apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Runtime/ConversationService.swift`
- `apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- `apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- `apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift`

Create tests:

- `apps/LocalAgentApp/LocalAgentAppTests/Runtime/ConversationDomainTests.swift`
- `apps/LocalAgentApp/LocalAgentAppTests/Runtime/ExecutionDomainTests.swift`
- `apps/LocalAgentApp/LocalAgentAppTests/Runtime/ExecutionDomainArchitectureTests.swift`
- `apps/LocalAgentApp/LocalAgentAppTests/Runtime/ChatInteractionCoordinatorTests.swift`
- `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ConversationViewModelTests.swift`
- `apps/LocalAgentApp/LocalAgentAppTests/Presentation/Runtime/AgentRunViewModelTests.swift`

---

### Task 1: Add Swift DTO Contract For Frame-Ref Execution

**Files:**
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift`

**Interfaces:**
- Produces: `ConversationRunFrameRefDTO`
- Produces: `ConversationRunFrameDTO`
- Produces: `PrepareUserTurnRequestDTO`
- Produces: `PreparedUserTurnDTO`
- Produces: `StartExecutionRequestDTO`
- Produces: `ObserveExecutionEventsRequestDTO`
- Produces: `BuildAgentRequestDTO`
- Produces: `ApproveToolRequestDTO`
- Produces: `ApprovalDecisionDTO`
- Updates: `RunHandleDTO.replayFromSequence`
- Produces: `CommitAssistantResultRequestDTO`
- Produces: `ConversationCommitResultDTO`

- [ ] **Step 1: Add failing DTO tests for execution trusted input**

Add to `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift`:

```swift
func testStartExecutionRequestEncodesConversationRunFrameRefOnly() throws {
    let request = StartExecutionRequestDTO(
        agentProfileId: "profile_1",
        userIntent: "answer the user",
        conversationRunFrameRef: ConversationRunFrameRefDTO(
            frameId: "frame_1",
            sessionId: "session_1",
            branchHeadId: "branch_head_1",
            userTurnId: "user_turn_1"
        ),
        options: ExecutionOptionsDTO()
    )

    let data = try JSONEncoder.agentOS.encode(request)
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertNotNil(object["conversation_run_frame_ref"])
    XCTAssertNil(object["conversation_run_frame"])
}

func testRunHandleDecodesReplayFromSequence() throws {
    let json = """
    {
      "run_id": "run_1",
      "replay_from_sequence": 0
    }
    """.data(using: .utf8)!

    let handle = try JSONDecoder.agentOS.decode(RunHandleDTO.self, from: json)

    XCTAssertEqual(handle.runId, "run_1")
    XCTAssertEqual(handle.replayFromSequence, 0)
}
```

- [ ] **Step 2: Add DTOs**

In `local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift`, add:

```swift
public struct ConversationRunFrameRefDTO: Codable, Equatable, Sendable {
    public var frameId: String
    public var sessionId: String
    public var branchHeadId: String
    public var userTurnId: String

    public init(
        frameId: String,
        sessionId: String,
        branchHeadId: String,
        userTurnId: String
    ) {
        self.frameId = frameId
        self.sessionId = sessionId
        self.branchHeadId = branchHeadId
        self.userTurnId = userTurnId
    }

    private enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case sessionId = "session_id"
        case branchHeadId = "branch_head_id"
        case userTurnId = "user_turn_id"
    }
}

public struct ConversationRunFrameDTO: Codable, Equatable, Sendable {
    public var frameRef: ConversationRunFrameRefDTO
    public var messages: [ConversationFrameMessageDTO]
    public var attachmentRefs: [String]

    public init(
        frameRef: ConversationRunFrameRefDTO,
        messages: [ConversationFrameMessageDTO],
        attachmentRefs: [String] = []
    ) {
        self.frameRef = frameRef
        self.messages = messages
        self.attachmentRefs = attachmentRefs
    }

    private enum CodingKeys: String, CodingKey {
        case frameRef = "frame_ref"
        case messages
        case attachmentRefs = "attachment_refs"
    }
}

public struct ConversationFrameMessageDTO: Codable, Equatable, Sendable {
    public var eventId: String
    public var role: String
    public var content: String

    public init(eventId: String, role: String, content: String) {
        self.eventId = eventId
        self.role = role
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case role
        case content
    }
}
```

- [ ] **Step 3: Add prepare and commit DTOs**

Add:

```swift
public struct PrepareUserTurnRequestDTO: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var parentEventId: String?
    public var text: String
    public var blobRefs: [String]

    public init(
        sessionId: String?,
        parentEventId: String?,
        text: String,
        blobRefs: [String] = []
    ) {
        self.sessionId = sessionId
        self.parentEventId = parentEventId
        self.text = text
        self.blobRefs = blobRefs
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case parentEventId = "parent_event_id"
        case text
        case blobRefs = "blob_refs"
    }
}

public struct PreparedUserTurnDTO: Codable, Equatable, Sendable {
    public var sessionId: String
    public var userMessageId: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO
    public var framePreview: ConversationRunFrameDTO?

    public init(
        sessionId: String,
        userMessageId: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO,
        framePreview: ConversationRunFrameDTO? = nil
    ) {
        self.sessionId = sessionId
        self.userMessageId = userMessageId
        self.conversationRunFrameRef = conversationRunFrameRef
        self.framePreview = framePreview
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case userMessageId = "user_message_id"
        case conversationRunFrameRef = "conversation_run_frame_ref"
        case framePreview = "frame_preview"
    }
}

public struct CommitAssistantResultRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var finalMessageId: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO

    public init(
        runId: String,
        finalMessageId: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO
    ) {
        self.runId = runId
        self.finalMessageId = finalMessageId
        self.conversationRunFrameRef = conversationRunFrameRef
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case finalMessageId = "final_message_id"
        case conversationRunFrameRef = "conversation_run_frame_ref"
    }
}

public struct ConversationCommitResultDTO: Codable, Equatable, Sendable {
    public var committedMessageId: String
    public var alreadyCommitted: Bool

    public init(committedMessageId: String, alreadyCommitted: Bool) {
        self.committedMessageId = committedMessageId
        self.alreadyCommitted = alreadyCommitted
    }

    private enum CodingKeys: String, CodingKey {
        case committedMessageId = "committed_message_id"
        case alreadyCommitted = "already_committed"
    }
}
```

- [ ] **Step 4: Add execution request DTO**

Add:

```swift
public struct ExecutionOptionsDTO: Codable, Equatable, Sendable {
    public var modelId: String?
    public var temperature: Double?
    public var topP: Double?

    public init(
        modelId: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.modelId = modelId
        self.temperature = temperature
        self.topP = topP
    }

    private enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case temperature
        case topP = "top_p"
    }
}

public struct StartExecutionRequestDTO: Codable, Equatable, Sendable {
    public var agentProfileId: String
    public var userIntent: String
    public var conversationRunFrameRef: ConversationRunFrameRefDTO
    public var options: ExecutionOptionsDTO

    public init(
        agentProfileId: String,
        userIntent: String,
        conversationRunFrameRef: ConversationRunFrameRefDTO,
        options: ExecutionOptionsDTO = ExecutionOptionsDTO()
    ) {
        self.agentProfileId = agentProfileId
        self.userIntent = userIntent
        self.conversationRunFrameRef = conversationRunFrameRef
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case agentProfileId = "agent_profile_id"
        case userIntent = "user_intent"
        case conversationRunFrameRef = "conversation_run_frame_ref"
        case options
    }
}
```

Add support DTOs used by bridge requests:

```swift
public struct ObserveExecutionEventsRequestDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var fromSequence: UInt64

    public init(runId: String, fromSequence: UInt64) {
        self.runId = runId
        self.fromSequence = fromSequence
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case fromSequence = "from_sequence"
    }
}

public struct BuildAgentRequestDTO: Codable, Equatable, Sendable {
    public var templateId: String

    public init(templateId: String) {
        self.templateId = templateId
    }

    private enum CodingKeys: String, CodingKey {
        case templateId = "template_id"
    }
}

public struct ApprovalDecisionDTO: Codable, Equatable, Sendable {
    public var approved: Bool
    public var reason: String?

    public init(approved: Bool, reason: String? = nil) {
        self.approved = approved
        self.reason = reason
    }
}

public struct ApproveToolRequestDTO: Codable, Equatable, Sendable {
    public var id: String
    public var decision: ApprovalDecisionDTO

    public init(id: String, decision: ApprovalDecisionDTO) {
        self.id = id
        self.decision = decision
    }
}

public struct EmptyAgentOSRequestDTO: Codable, Equatable, Sendable {
    public init() {}
}

public struct EmptyAgentOSResponseDTO: Codable, Equatable, Sendable {
    public init() {}
}
```

- [ ] **Step 5: Update `RunHandleDTO`**

Change `RunHandleDTO`:

```swift
public struct RunHandleDTO: Codable, Equatable, Sendable {
    public var runId: String
    public var replayFromSequence: UInt64

    public init(runId: String, replayFromSequence: UInt64 = 0) {
        self.runId = runId
        self.replayFromSequence = replayFromSequence
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case replayFromSequence = "replay_from_sequence"
    }
}
```

- [ ] **Step 6: Keep legacy `StartRunRequestDTO` temporarily**

Keep the existing `StartRunRequestDTO` for compatibility with the current `RuntimeClient.startRun(_:)` until Task 7. Add this attribute above the existing declaration without changing its stored properties or coding keys:

```swift
@available(*, deprecated, message: "Use StartExecutionRequestDTO with ConversationRunFrameRefDTO")
```

- [ ] **Step 7: Run DTO tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter AgentOSDTOTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalAgentBridge/AgentOSDTOs.swift \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/AgentOSDTOTests.swift
git commit -m "feat: add swift conversation frame execution DTOs"
```

---

### Task 2: Split Toolkit Bridge Clients Over The C ABI Gateway

**Files:**
- Create: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentBridge/ConversationBridgeClient.swift`
- Create: `local-ios-agent/toolkit/Sources/LocalAgentBridge/ExecutionBridgeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/MockRuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`

**Interfaces:**
- Produces: `ConversationBridgeClient`
- Produces: `ExecutionBridgeClient`
- Produces: `RustAgentOSBridgeGateway`
- Keeps: `RuntimeClient` as legacy aggregate protocol.

- [ ] **Step 1: Add failing bridge contract tests**

In `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`, add tests that use a fake gateway or fake C function table:

```swift
func testExecutionBridgeStartRunUsesStartExecutionRequest() async throws {
    let gateway = RecordingAgentOSBridgeGateway()
    let legacyClient = MockRuntimeClient()
    let client = RustExecutionBridgeClient(
        gateway: gateway,
        legacyClient: legacyClient
    )
    let request = StartExecutionRequestDTO(
        agentProfileId: "profile_1",
        userIntent: "answer",
        conversationRunFrameRef: ConversationRunFrameRefDTO(
            frameId: "frame_1",
            sessionId: "session_1",
            branchHeadId: "branch_head_1",
            userTurnId: "user_turn_1"
        )
    )
    gateway.nextDecodedResponse = RunHandleDTO(runId: "run_1", replayFromSequence: 0)

    let handle = try await client.startRun(request)

    XCTAssertEqual(handle.runId, "run_1")
    XCTAssertEqual(gateway.recordedOperation, .startExecutionRun)
    XCTAssertTrue(gateway.recordedJSON.contains("conversation_run_frame_ref"))
    XCTAssertFalse(gateway.recordedJSON.contains("conversation_run_frame\""))
}
```

- [ ] **Step 2: Add bridge protocols**

Create `local-ios-agent/toolkit/Sources/LocalAgentBridge/ConversationBridgeClient.swift`:

```swift
public protocol ConversationBridgeClient: Sendable {
    func listSessions() async throws -> [ConversationSummaryDTO]
    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func forkSession(sessionId: String, leafId: String) async throws -> String
    func archiveSession(sessionId: String) async throws
    func renameSession(sessionId: String, title: String) async throws
    func deleteSession(sessionId: String) async throws
    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO
}
```

Create `local-ios-agent/toolkit/Sources/LocalAgentBridge/ExecutionBridgeClient.swift`:

```swift
public protocol ExecutionBridgeClient: Sendable {
    func listAgentProfiles() async throws -> [AgentProfileDTO]
    func buildAgent(templateId: String) async throws -> AgentProfileDTO
    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO
    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error>
    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws
    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO
    func cancelRun(runId: String) async throws -> RuntimeEventDTO
    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel
    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws
}
```

Use `RuntimeEventDTO` for the first migration step so existing reducers still work. Rename to `ExecutionEventDTO` only after Rust exposes a distinct DTO.

- [ ] **Step 3: Add gateway**

Create `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustAgentOSBridgeGateway.swift`:

```swift
public enum RustAgentOSOperation: String, Sendable {
    case listAgentProfiles = "list_agent_profiles"
    case buildAgent = "build_agent"
    case prepareUserTurn = "prepare_user_turn"
    case commitAssistantResult = "commit_assistant_result"
    case startExecutionRun = "start_execution_run"
    case observeExecutionEvents = "observe_execution_events"
    case approveTool = "approve_tool"
    case updateRuntimeOptions = "update_runtime_options"
}

public protocol RustAgentOSBridgeGateway: Sendable {
    func request<Request: Encodable, Response: Decodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request,
        as response: Response.Type
    ) async throws -> Response

    func stream<Request: Encodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error>
}
```

- [ ] **Step 4: Implement Rust bridge clients**

In the same files or separate concrete implementation files, add:

```swift
public struct RustConversationBridgeClient: ConversationBridgeClient {
    private let gateway: any RustAgentOSBridgeGateway
    private let legacyClient: any ConversationRuntimeClient

    public init(
        gateway: any RustAgentOSBridgeGateway,
        legacyClient: any ConversationRuntimeClient
    ) {
        self.gateway = gateway
        self.legacyClient = legacyClient
    }

    public func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        try await gateway.request(.prepareUserTurn, request, as: PreparedUserTurnDTO.self)
    }

    public func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        try await gateway.request(.commitAssistantResult, request, as: ConversationCommitResultDTO.self)
    }

    public func listSessions() async throws -> [ConversationSummaryDTO] {
        try await legacyClient.conversationSummaries()
    }

    public func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        try await legacyClient.activeBranch(sessionId: sessionId, leafId: leafId)
    }

    public func forkSession(sessionId: String, leafId: String) async throws -> String {
        try await legacyClient.forkSession(sessionId: sessionId, leafId: leafId)
    }

    public func archiveSession(sessionId: String) async throws {
        try await legacyClient.archiveSession(sessionId: sessionId)
    }

    public func renameSession(sessionId: String, title: String) async throws {
        try await legacyClient.renameSession(sessionId: sessionId, title: title)
    }

    public func deleteSession(sessionId: String) async throws {
        try await legacyClient.deleteSession(sessionId: sessionId)
    }
}
```

Implement `RustExecutionBridgeClient`:

```swift
public struct RustExecutionBridgeClient: ExecutionBridgeClient {
    private let gateway: any RustAgentOSBridgeGateway
    private let legacyClient: any RuntimeClient

    public init(
        gateway: any RustAgentOSBridgeGateway,
        legacyClient: any RuntimeClient
    ) {
        self.gateway = gateway
        self.legacyClient = legacyClient
    }

    public func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await gateway.request(.startExecutionRun, request, as: RunHandleDTO.self)
    }

    public func listAgentProfiles() async throws -> [AgentProfileDTO] {
        try await gateway.request(
            .listAgentProfiles,
            EmptyAgentOSRequestDTO(),
            as: [AgentProfileDTO].self
        )
    }

    public func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        try await gateway.request(
            .buildAgent,
            BuildAgentRequestDTO(templateId: templateId),
            as: AgentProfileDTO.self
        )
    }

    public func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        gateway.stream(
            .observeExecutionEvents,
            ObserveExecutionEventsRequestDTO(runId: runId, fromSequence: fromSequence)
        )
    }

    public func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        _ = try await gateway.request(
            .approveTool,
            ApproveToolRequestDTO(id: id, decision: decision),
            as: EmptyAgentOSResponseDTO.self
        )
    }

    public func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try await legacyClient.loadDebugArchive(runId)
    }

    public func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        try await legacyClient.submitToolResult(runId: runId, result: result)
    }

    public func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await legacyClient.cancel(runId: runId)
    }

    public func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        _ = try await gateway.request(
            .updateRuntimeOptions,
            options,
            as: EmptyAgentOSResponseDTO.self
        )
    }
}
```

- [ ] **Step 5: Keep `RuntimeClient` as compatibility aggregate**

Do not remove existing `RuntimeClient` requirements in this task. Add code comments near `RuntimeClient`:

```swift
/// Compatibility aggregate used by the existing chat path.
/// New code should depend on ConversationBridgeClient and ExecutionBridgeClient.
```

- [ ] **Step 6: Update `MockRuntimeClient`**

Make `MockRuntimeClient` conform to `ConversationBridgeClient` and `ExecutionBridgeClient` with deterministic arrays:

```swift
public private(set) var preparedUserTurnRequests: [PrepareUserTurnRequestDTO] = []
public private(set) var startedExecutionRequests: [StartExecutionRequestDTO] = []
public var executionEventsByRunId: [String: [RuntimeEventDTO]] = [:]
```

`observeEvents(runId:fromSequence:)` filters events by sequence when the DTO has sequence. If current DTO sequence is not modeled, return the whole array for this task and add the sequence assertion in Task 5 when the reducer state is introduced.

- [ ] **Step 7: Run bridge tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test --filter RustRuntimeClientContractTests
swift test --filter RustRuntimeClientStreamingTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/toolkit/Sources/LocalAgentBridge \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests
git commit -m "feat: split swift rust bridge clients"
```

---

### Task 3: Add App Domain Protocols And Focused Execution Services

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Conversation/ConversationDomain.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Conversation/ConversationDomainAdapter.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ExecutionDomain.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ExecutionDomainAdapter.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/AgentProfileService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/AgentCompositionService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/RunLifecycleService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/RunEventStreamService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ToolApprovalService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/RunDebugService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/InferenceSettingsService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ConversationDomainTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ExecutionDomainTests.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ExecutionDomainArchitectureTests.swift`

**Interfaces:**
- Produces: `ConversationDomain`
- Produces: `ExecutionDomain`
- Produces focused service wrappers so `ExecutionDomainAdapter` does not become the new big object.

- [ ] **Step 1: Add failing architecture test**

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ExecutionDomainArchitectureTests.swift`:

```swift
import XCTest
@testable import LocalAgentApp

final class ExecutionDomainArchitectureTests: XCTestCase {
    func testExecutionDomainAdapterUsesFocusedServices() throws {
        let adapter = ExecutionDomainAdapter(
            profiles: AgentProfileService.preview,
            composition: AgentCompositionService.preview,
            lifecycle: RunLifecycleService.preview,
            events: RunEventStreamService.preview,
            tools: ToolApprovalService.preview,
            debug: RunDebugService.preview,
            inference: InferenceSettingsService.preview
        )

        XCTAssertNotNil(adapter)
    }
}
```

- [ ] **Step 2: Add conversation domain**

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Conversation/ConversationDomain.swift`:

```swift
import LocalAgentBridge

protocol ConversationDomain: Sendable {
    func listSessions() async throws -> [ConversationSummaryDTO]
    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func forkSession(sessionId: String, leafId: String) async throws -> String
    func archiveSession(sessionId: String) async throws
    func renameSession(sessionId: String, title: String) async throws
    func deleteSession(sessionId: String) async throws
    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO
}
```

Create `ConversationDomainAdapter.swift`:

```swift
import LocalAgentBridge

struct ConversationDomainAdapter: ConversationDomain {
    private let bridge: any ConversationBridgeClient

    init(bridge: any ConversationBridgeClient) {
        self.bridge = bridge
    }

    func listSessions() async throws -> [ConversationSummaryDTO] {
        try await bridge.listSessions()
    }

    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        try await bridge.prepareUserTurn(request)
    }

    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        try await bridge.commitAssistantResult(request)
    }

    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        try await bridge.activeBranch(sessionId: sessionId, leafId: leafId)
    }

    func forkSession(sessionId: String, leafId: String) async throws -> String {
        try await bridge.forkSession(sessionId: sessionId, leafId: leafId)
    }

    func archiveSession(sessionId: String) async throws {
        try await bridge.archiveSession(sessionId: sessionId)
    }

    func renameSession(sessionId: String, title: String) async throws {
        try await bridge.renameSession(sessionId: sessionId, title: title)
    }

    func deleteSession(sessionId: String) async throws {
        try await bridge.deleteSession(sessionId: sessionId)
    }
}
```

- [ ] **Step 3: Add execution domain**

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution/ExecutionDomain.swift`:

```swift
import LocalAgentBridge

protocol ExecutionDomain: Sendable {
    func listAgentProfiles() async throws -> [AgentProfileDTO]
    func buildAgent(templateId: String) async throws -> AgentProfileDTO
    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO
    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error>
    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws
    func cancelRun(runId: String) async throws -> RuntimeEventDTO
    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel
    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws
}
```

- [ ] **Step 4: Add focused services**

Each focused service wraps only one concern and depends on the narrow bridge it needs.

Create `RunLifecycleService.swift`:

```swift
import LocalAgentBridge

struct RunLifecycleService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await bridge.startRun(request)
    }

    func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await bridge.cancelRun(runId: runId)
    }
}
```

Create `RunEventStreamService.swift`:

```swift
import LocalAgentBridge

struct RunEventStreamService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        bridge.observeEvents(runId: runId, fromSequence: fromSequence)
    }
}
```

Create `AgentProfileService.swift`:

```swift
import LocalAgentBridge

struct AgentProfileService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func listAgentProfiles() async throws -> [AgentProfileDTO] {
        try await bridge.listAgentProfiles()
    }
}
```

Create `AgentCompositionService.swift`:

```swift
import LocalAgentBridge

struct AgentCompositionService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        try await bridge.buildAgent(templateId: templateId)
    }
}
```

Create `ToolApprovalService.swift`:

```swift
import LocalAgentBridge

struct ToolApprovalService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        try await bridge.approveTool(id: id, decision: decision)
    }
}
```

Create `RunDebugService.swift`:

```swift
import LocalAgentBridge

struct RunDebugService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try await bridge.loadDebugArchive(runId)
    }
}
```

Create `InferenceSettingsService.swift`:

```swift
import LocalAgentBridge

struct InferenceSettingsService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        try await bridge.updateRuntimeOptions(options)
    }
}
```

- [ ] **Step 5: Add execution facade**

Create `ExecutionDomainAdapter.swift`:

```swift
import LocalAgentBridge

struct ExecutionDomainAdapter: ExecutionDomain {
    private let profiles: AgentProfileService
    private let composition: AgentCompositionService
    private let lifecycle: RunLifecycleService
    private let events: RunEventStreamService
    private let tools: ToolApprovalService
    private let debug: RunDebugService
    private let inference: InferenceSettingsService

    init(
        profiles: AgentProfileService,
        composition: AgentCompositionService,
        lifecycle: RunLifecycleService,
        events: RunEventStreamService,
        tools: ToolApprovalService,
        debug: RunDebugService,
        inference: InferenceSettingsService
    ) {
        self.profiles = profiles
        self.composition = composition
        self.lifecycle = lifecycle
        self.events = events
        self.tools = tools
        self.debug = debug
        self.inference = inference
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await lifecycle.startRun(request)
    }

    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        events.observeEvents(runId: runId, fromSequence: fromSequence)
    }

    func listAgentProfiles() async throws -> [AgentProfileDTO] {
        try await profiles.listAgentProfiles()
    }

    func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        try await composition.buildAgent(templateId: templateId)
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        try await tools.approveTool(id: id, decision: decision)
    }

    func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await lifecycle.cancelRun(runId: runId)
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try await debug.loadDebugArchive(runId)
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        try await inference.updateRuntimeOptions(options)
    }
}
```

- [ ] **Step 6: Add preview fakes for tests**

For each focused service, add a test-only or internal static factory:

```swift
#if DEBUG
static var preview: Self {
    Self(bridge: MockRuntimeClient())
}
#endif
```

If app target visibility blocks `#if DEBUG` factories, create equivalent factories in `LocalAgentAppTests/Runtime/ExecutionDomainTestSupport.swift`.

- [ ] **Step 7: Run app domain tests**

Run:

```bash
cd local-ios-agent/apps/LocalAgentApp
swift test --filter ConversationDomainTests
swift test --filter ExecutionDomainTests
swift test --filter ExecutionDomainArchitectureTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Conversation \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/Execution \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime
git commit -m "feat: add swift conversation execution domains"
```

---

### Task 4: Extract Conversation View Model Boundary

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ConversationService.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/ConversationViewModelTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`

**Interfaces:**
- Produces: `ConversationViewModel`
- Keeps conversation list, branch selection, fork, edit, delete, rename, and draft targeting out of `AgentRunViewModel`.

- [ ] **Step 1: Add failing view model tests**

Create `ConversationViewModelTests.swift`:

```swift
import XCTest
@testable import LocalAgentApp

@MainActor
final class ConversationViewModelTests: XCTestCase {
    func testLoadConversationsProjectsSections() async throws {
        let domain = FakeConversationDomain(
            summaries: [
                ConversationSummaryDTO(
                    sessionId: "session_1",
                    title: "First",
                    activeLeafId: "leaf_1",
                    lastEventId: "event_1",
                    lastUpdatedSequence: 1,
                    lastUpdatedAtMillis: 1_700_000_000_000,
                    searchText: "first"
                )
            ]
        )
        let viewModel = ConversationViewModel(domain: domain)

        try await viewModel.loadConversations()

        XCTAssertEqual(viewModel.conversations.map(\.sessionId), ["session_1"])
    }
}
```

- [ ] **Step 2: Create `ConversationViewModel`**

Create `ConversationViewModel.swift`:

```swift
import Foundation
import LocalAgentBridge

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published private(set) var conversations: [ConversationSummaryViewState] = []
    @Published private(set) var sections: [ConversationSectionViewState] = []
    @Published var searchQuery = ""
    @Published var draft = UserDraftViewState()
    @Published private(set) var currentSessionId: String?

    private let domain: any ConversationDomain

    init(domain: any ConversationDomain) {
        self.domain = domain
    }

    func loadConversations() async throws {
        let summaries = try await domain.listSessions()
        conversations = ConversationService.projectSummaries(summaries)
        sections = ConversationService.groupConversations(
            conversations,
            searchQuery: searchQuery
        )
    }
}
```

- [ ] **Step 3: Move conversation operations out of `AgentViewModel`**

In `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`, keep public methods used by existing views, but delegate conversation operations to `ConversationViewModel` where practical:

```swift
func loadConversations() async {
    await perform {
        try await conversation.loadConversations()
        state.conversations = conversation.conversations
    }
}
```

Do not move run streaming state in this task.

- [ ] **Step 4: Keep `AgentViewState` compatibility**

Keep existing `AgentViewState.conversations`, `currentSessionId`, and `draft` so current SwiftUI views compile. Treat them as projection state while the VM split is incomplete.

- [ ] **Step 5: Run tests**

Run:

```bash
cd local-ios-agent/apps/LocalAgentApp
swift test --filter ConversationViewModelTests
swift test --filter AgentViewModelTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ConversationViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ConversationService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat
git commit -m "feat: extract conversation view model boundary"
```

---

### Task 5: Add Agent Run View Model And Replay-Aware Reducer State

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Runtime/AgentRunViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Runtime/AgentRunViewModelTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift`

**Interfaces:**
- Produces: `AgentRunViewModel`
- Tracks: `runState`, `events`, `toolCalls`, `approval`, `streamBuffer`, `lastAppliedSequence`.

- [ ] **Step 1: Add failing replay test**

Create `AgentRunViewModelTests.swift`:

```swift
import XCTest
import LocalAgentBridge
@testable import LocalAgentApp

@MainActor
final class AgentRunViewModelTests: XCTestCase {
    func testAppliesEventsOnceBySequence() {
        let viewModel = AgentRunViewModel()
        let event = RuntimeEventDTO.runStarted(runId: "run_1", sequence: 1)

        viewModel.apply(event)
        viewModel.apply(event)

        XCTAssertEqual(viewModel.events.count, 1)
        XCTAssertEqual(viewModel.lastAppliedSequence, 1)
    }
}
```

If `RuntimeEventDTO` does not yet expose `sequence`, add a temporary helper in test fixtures and complete the DTO sequence field in the same task.

- [ ] **Step 2: Add `AgentRunViewModel`**

Create:

```swift
import Foundation
import LocalAgentBridge

@MainActor
final class AgentRunViewModel: ObservableObject {
    @Published private(set) var runState: AgentRunPhase = .idle
    @Published private(set) var events: [RuntimeEventDTO] = []
    @Published private(set) var toolCalls: [ToolExecutionRequestDTO] = []
    @Published private(set) var approval: ApprovalProtocolRequestDTO?
    @Published private(set) var streamBuffer = ""
    private(set) var lastAppliedSequence: UInt64 = 0

    func begin(runId: String, replayFromSequence: UInt64) {
        runState = .running(runId: runId)
        lastAppliedSequence = replayFromSequence
    }

    func apply(_ event: RuntimeEventDTO) {
        guard let sequence = event.sequence else {
            events.append(event)
            return
        }
        guard sequence > lastAppliedSequence else {
            return
        }
        lastAppliedSequence = sequence
        events.append(event)
    }
}
```

Define `AgentRunPhase` near the view model or reuse the existing phase type in `AgentViewState` if it already models the same states.

- [ ] **Step 3: Make reducer sequence-aware**

In `RuntimeEventReducer.apply`, before mutating `AgentViewState`, ignore events with a sequence lower than or equal to `state.lastAppliedRuntimeSequence`.

Add to `AgentViewState`:

```swift
var lastAppliedRuntimeSequence: UInt64 = 0
```

The reducer must update this value only after applying a sequenced event.

- [ ] **Step 4: Preserve stream buffer behavior**

Move only the run-specific fields that can be tested without UI changes. Leave the existing `AgentRuntimeService.consume` stream-buffer behavior intact until the coordinator path owns streaming.

- [ ] **Step 5: Run tests**

Run:

```bash
cd local-ios-agent/apps/LocalAgentApp
swift test --filter AgentRunViewModelTests
swift test --filter RuntimeEventReducerTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Runtime/AgentRunViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/RuntimeEventReducer.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Runtime \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/State/RuntimeEventReducerTests.swift
git commit -m "feat: add replay aware agent run view model"
```

---

### Task 6: Add Chat Interaction Coordinator

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ChatInteractionCoordinatorTests.swift`

**Interfaces:**
- Produces: `ChatInteractionCoordinator`
- Orchestrates: `ConversationDomain.prepareUserTurn -> ExecutionDomain.startRun -> ExecutionDomain.observeEvents -> ConversationDomain.commitAssistantResult`
- Handles: completed-but-uncommitted recovery retry.

- [ ] **Step 1: Add failing coordinator happy-path test**

Create `ChatInteractionCoordinatorTests.swift`:

```swift
import XCTest
import LocalAgentBridge
@testable import LocalAgentApp

@MainActor
final class ChatInteractionCoordinatorTests: XCTestCase {
    func testSendMessagePreparesFrameRefStartsRunObservesAndCommits() async throws {
        let conversation = FakeConversationDomain(
            preparedTurn: PreparedUserTurnDTO(
                sessionId: "session_1",
                userMessageId: "user_turn_1",
                conversationRunFrameRef: ConversationRunFrameRefDTO(
                    frameId: "frame_1",
                    sessionId: "session_1",
                    branchHeadId: "branch_head_1",
                    userTurnId: "user_turn_1"
                )
            )
        )
        let execution = FakeExecutionDomain(
            handle: RunHandleDTO(runId: "run_1", replayFromSequence: 0),
            events: [
                .runStarted(runId: "run_1", sequence: 1),
                .assistantMessageFinal(runId: "run_1", messageId: "assistant_1", sequence: 2)
            ]
        )
        let coordinator = ChatInteractionCoordinator(
            conversation: conversation,
            execution: execution
        )

        try await coordinator.sendMessage(
            text: "hello",
            sessionId: "session_1",
            parentEventId: nil,
            agentProfileId: "profile_1",
            options: ExecutionOptionsDTO()
        )

        XCTAssertEqual(execution.startedRequests.first?.conversationRunFrameRef.frameId, "frame_1")
        XCTAssertEqual(conversation.committedRequests.first?.runId, "run_1")
        XCTAssertEqual(conversation.committedRequests.first?.finalMessageId, "assistant_1")
    }
}
```

- [ ] **Step 2: Implement coordinator**

Create `ChatInteractionCoordinator.swift`:

```swift
import LocalAgentBridge

@MainActor
final class ChatInteractionCoordinator {
    private let conversation: any ConversationDomain
    private let execution: any ExecutionDomain

    init(
        conversation: any ConversationDomain,
        execution: any ExecutionDomain
    ) {
        self.conversation = conversation
        self.execution = execution
    }

    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @escaping (RuntimeEventDTO) -> Void = { _ in }
    ) async throws {
        let preparedTurn = try await conversation.prepareUserTurn(
            PrepareUserTurnRequestDTO(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: text
            )
        )
        let handle = try await execution.startRun(
            StartExecutionRequestDTO(
                agentProfileId: agentProfileId,
                userIntent: text,
                conversationRunFrameRef: preparedTurn.conversationRunFrameRef,
                options: options
            )
        )

        var finalMessageId: String?
        for try await event in execution.observeEvents(
            runId: handle.runId,
            fromSequence: handle.replayFromSequence
        ) {
            onEvent(event)
            if let messageId = event.finalAssistantMessageId {
                finalMessageId = messageId
            }
        }

        if let finalMessageId {
            _ = try await conversation.commitAssistantResult(
                CommitAssistantResultRequestDTO(
                    runId: handle.runId,
                    finalMessageId: finalMessageId,
                    conversationRunFrameRef: preparedTurn.conversationRunFrameRef
                )
            )
        }
    }
}
```

Add `RuntimeEventDTO.finalAssistantMessageId` as a computed property in a local extension if it is not already available.

- [ ] **Step 3: Add commit retry behavior**

Add a second test that makes the first commit call throw, then calls `recoverCompletedRunCommit` with the same ids:

```swift
func testCommitAssistantResultRetryIsAllowedAfterFirstFailure() async throws {
    let frameRef = ConversationRunFrameRefDTO(
        frameId: "frame_1",
        sessionId: "session_1",
        branchHeadId: "branch_head_1",
        userTurnId: "user_turn_1"
    )
    let conversation = FakeConversationDomain(
        commitResults: [
            .failure(CommitFailure.transient),
            .success(ConversationCommitResultDTO(
                committedMessageId: "assistant_1",
                alreadyCommitted: true
            ))
        ]
    )
    let coordinator = ChatInteractionCoordinator(
        conversation: conversation,
        execution: FakeExecutionDomain()
    )

    try await coordinator.recoverCompletedRunCommit(
        runId: "run_1",
        finalMessageId: "assistant_1",
        frameRef: frameRef
    )

    XCTAssertEqual(conversation.committedRequests.count, 1)
}
```

The coordinator should let the first send fail if commit fails, but expose a method:

```swift
func recoverCompletedRunCommit(
    runId: String,
    finalMessageId: String,
    frameRef: ConversationRunFrameRefDTO
) async throws
```

This method calls the same `commitAssistantResult` request and treats `alreadyCommitted == true` as success.

- [ ] **Step 4: Add cancel and approval pass-through methods**

Add:

```swift
func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
    try await execution.approveTool(id: id, decision: decision)
}

func cancelRun(runId: String) async throws {
    _ = try await execution.cancelRun(runId: runId)
}
```

- [ ] **Step 5: Run coordinator tests**

Run:

```bash
cd local-ios-agent/apps/LocalAgentApp
swift test --filter ChatInteractionCoordinatorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/ChatInteractionCoordinator.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/ChatInteractionCoordinatorTests.swift
git commit -m "feat: add chat interaction coordinator"
```

---

### Task 7: Route Existing App Facade Through The New Path

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift`

**Interfaces:**
- Keeps: `AgentRuntimeServicing` for current UI.
- Adds: coordinator-backed send-message path when new bridge capability is available.
- Keeps: legacy `sendMessageStream` fallback until Rust and Swift app migration are complete.

- [ ] **Step 1: Add test for new path routing**

In `AgentRuntimeServiceTests.swift`, add:

```swift
func testSendMessageUsesCoordinatorWhenInjected() async throws {
    let coordinator = RecordingChatInteractionCoordinator()
    let service = AgentRuntimeService(
        runtimeClient: MockRuntimeClient(),
        toolDriver: .fixture,
        coordinator: coordinator
    )

    _ = try await service.sendMessage(
        "hello",
        state: AgentViewState(phase: .ready, currentSessionId: "session_1")
    )

    XCTAssertEqual(coordinator.sentMessages, ["hello"])
}
```

- [ ] **Step 2: Add optional coordinator injection**

Modify `AgentRuntimeService` initializer:

```swift
private let coordinator: ChatInteractionCoordinating?

init(
    runtimeClient: any RuntimeClient,
    toolDriver: MinimalHostToolDriver,
    streamFlushNanoseconds: UInt64 = 50_000_000,
    coordinator: ChatInteractionCoordinating? = nil
) {
    self.runtimeClient = runtimeClient
    self.toolDriver = toolDriver
    self.streamFlushNanoseconds = streamFlushNanoseconds
    self.coordinator = coordinator
}
```

Use a small protocol for testability:

```swift
protocol ChatInteractionCoordinating: AnyObject, Sendable {
    @MainActor
    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @escaping (RuntimeEventDTO) -> Void
    ) async throws
}
```

- [ ] **Step 3: Route `sendMessage` through coordinator when available**

At the top of `AgentRuntimeService.sendMessage`, after duplicate-run guard:

```swift
if let coordinator {
    try await coordinator.sendMessage(
        text: text,
        sessionId: state.currentSessionId,
        parentEventId: state.draft.targetParentEventId,
        agentProfileId: state.selectedAgentProfileId,
        options: state.executionOptions,
        onEvent: { event in
            await onEvent(event)
        }
    )
    var nextState = state
    nextState.draft = UserDraftViewState()
    nextState.phase = .ready
    return nextState
}
```

If `AgentViewState` does not yet have `selectedAgentProfileId` or `executionOptions`, add computed compatibility defaults:

```swift
var selectedAgentProfileId: String { provider.activeProfileId ?? "default" }
var executionOptions: ExecutionOptionsDTO { ExecutionOptionsDTO() }
```

- [ ] **Step 4: Mark legacy path**

Near the existing streaming send path in `AgentRuntimeService.swift`, add:

```swift
private let legacyCompatibilityStreamingPath = "LEGACY_COMPATIBILITY_STREAMING_PATH"
```

Use it in a local debug log or keep it as a private constant referenced by a test. This mirrors the Rust legacy marker and makes the migration state explicit.

- [ ] **Step 5: Keep tool continuation on old path only**

Do not route `continueToolsIfNeeded` through the coordinator in this task. The new Rust execution path owns the tool loop internally, so Swift should stop manually continuing tool calls only after the runtime event contract proves it. Keep the existing method as part of the legacy fallback.

- [ ] **Step 6: Run facade tests**

Run:

```bash
cd local-ios-agent/apps/LocalAgentApp
swift test --filter AgentRuntimeServiceTests
swift test --filter AgentViewModelTests
swift test --filter RustRuntimeAppIntegrationTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift
git commit -m "feat: route swift chat through coordinator path"
```

---

### Task 8: Final Swift Verification And Migration Notes

**Files:**
- Modify only files needed for fixes discovered by verification.
- Optionally create: `local-ios-agent/docs/swift-conversation-execution-migration-notes.md`

**Interfaces:**
- Verifies Swift bridge and app adoption.
- Leaves old UI route available while marking the migration boundary.

- [ ] **Step 1: Run toolkit tests**

Run:

```bash
cd local-ios-agent/toolkit
swift test
```

Expected: PASS.

- [ ] **Step 2: Run app tests**

Run:

```bash
cd local-ios-agent/apps/LocalAgentApp
swift test
```

Expected: PASS.

- [ ] **Step 3: Run integrated Rust and Swift bridge smoke test**

After Rust plan Task 6 has landed, run:

```bash
cd local-ios-agent
swift test --package-path toolkit --filter RustRuntimeClientContractTests
cargo test --manifest-path rust-core/Cargo.toml --test integration ffi_bridge -- --nocapture
```

Expected: PASS.

- [ ] **Step 4: Verify migration markers**

Run:

```bash
rg "LEGACY_COMPATIBILITY_STREAMING_PATH|ConversationRunFrameRefDTO|StartExecutionRequestDTO|ChatInteractionCoordinator" local-ios-agent
rg "conversationRunFrame:" local-ios-agent/toolkit local-ios-agent/apps/LocalAgentApp
```

Expected:

```text
First command finds the new contract and legacy markers.
Second command finds no trusted execution start request that passes a full frame.
```

- [ ] **Step 5: Commit verification fixes if needed**

If fixes were required:

```bash
git add local-ios-agent/toolkit local-ios-agent/apps/LocalAgentApp
git commit -m "test: verify swift conversation execution adoption"
```

If no fixes were required, do not create a commit.

---

## Self-Review

Spec coverage:

- Rust trusted input is represented as `ConversationRunFrameRefDTO` in Task 1.
- Full frame DTO is restricted to preview and debug in Task 1.
- Bridge split is handled in Task 2.
- App domain split is handled in Task 3.
- Execution remains decomposed into focused services in Task 3.
- Conversation VM and run VM are split in Tasks 4 and 5.
- Coordinator orchestration is explicit in Task 6.
- Legacy app path is preserved and marked in Task 7.
- Verification covers toolkit, app, bridge, and migration marker scans in Task 8.

Migration safety:

- Existing `RuntimeClient`, `AgentRuntimeService`, and `AgentViewModel` remain available during the migration.
- The new path is injectable before it is the only production path.
- Swift stops manually driving the tool loop only after the new Rust execution event stream is available.
- Event replay is represented by `RunHandleDTO.replayFromSequence` and `observeEvents(runId:fromSequence:)`.
- Final assistant commit retry is modeled in `ChatInteractionCoordinator`.

Boundary clarity:

- Conversation owns session, branch, user turn preparation, frame ref creation, and assistant result commit.
- Execution owns run start, event replay, cancellation, approval, debug, composition, and inference settings.
- `ExecutionDomainAdapter` delegates to focused services and does not contain model prompt assembly, tool loop logic, or conversation projection logic.
