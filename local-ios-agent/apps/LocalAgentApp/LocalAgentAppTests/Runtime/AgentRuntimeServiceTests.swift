import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Agent runtime service")
struct AgentRuntimeServiceTests {
    @Test("prepare creates a session and registers debug.echo")
    func prepareCreatesSessionAndRegistersDebugEcho() async throws {
        let client = ScriptedRuntimeClient()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.prepare()
        let schemas = await client.registeredToolSchemas

        #expect(state.phase == .ready)
        #expect(state.currentSessionId == "session_1")
        #expect(schemas.map(\.name) == ["debug.echo"])
    }

    @Test("send applies completed mock chat events")
    func sendAppliesCompletedMockChatEvents() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_1", kind: .userMessage, payload: "hello"),
                    event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                    event(id: "delta_1", kind: .assistantTextDelta, payload: "Mock "),
                    event(id: "delta_2", kind: .assistantTextDelta, payload: "response to: hello"),
                    event(id: "completed", kind: .assistantMessageCompleted, payload: "Mock response to: hello"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(await client.sentMessages.map(\.text) == ["hello"])
        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text) == ["hello", "Mock response to: hello"])
    }

    @Test("second send is rejected while first send is still in flight")
    func secondSendIsRejectedWhileFirstSendIsInFlight() async throws {
        let client = BlockingSendRuntimeClient()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = try await service.prepare()

        async let firstSend = service.sendMessage("first", state: state)
        await client.waitForSendStarted()

        do {
            _ = try await service.sendMessage("second", state: state)
            Issue.record("Expected duplicate run rejection")
        } catch let error as AgentRuntimeServiceError {
            #expect(error == .duplicateRun)
        }

        await client.completeSend(with: AgentTurnResultDTO(
            runId: "run_1",
            state: .completed,
            events: [
                event(id: "user_1", kind: .userMessage, payload: "first"),
                event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                event(id: "completed", kind: .assistantMessageCompleted, payload: "Mock response to: first"),
            ],
            pendingToolCallId: nil
        ))
        _ = try await firstSend

        #expect(await client.sentMessages.map(\.text) == ["first"])
    }

    @Test("failed tool continuation releases active run guard")
    func failedToolContinuationReleasesActiveRunGuard() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .waitingTool,
                events: [
                    event(id: "user_1", kind: .userMessage, payload: "use tool debug.echo"),
                    event(
                        id: "tool_call",
                        kind: .toolCallRequested,
                        payload: #"{"call_id":"call_missing","name":"debug.echo","arguments_json":"{\"text\":\"hello\"}","route_state":"ready","route_reason":null}"#
                    ),
                ],
                pendingToolCallId: "call_missing"
            ),
            AgentTurnResultDTO(
                runId: "run_2",
                state: .completed,
                events: [
                    event(id: "user_2", kind: .userMessage, payload: "hello", runId: "run_2"),
                    event(id: "assistant_started_2", kind: .assistantMessageStarted, payload: "run run_2", runId: "run_2"),
                    event(id: "completed_2", kind: .assistantMessageCompleted, payload: "Mock response to: hello", runId: "run_2"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.prepare()
        do {
            _ = try await service.sendMessage("use tool debug.echo", state: state)
            Issue.record("Expected missing pending tool request")
        } catch let error as AgentRuntimeServiceError {
            #expect(error == .missingPendingToolRequest("call_missing"))
        }

        let recovered = try await service.sendMessage("hello", state: state)
        #expect(recovered.phase == .ready)
        #expect(recovered.messages.map(\.text).contains("Mock response to: hello"))
    }

    @Test("waiting tool turn is executed and submitted once")
    func waitingToolTurnIsExecutedAndSubmittedOnce() async throws {
        let client = ScriptedRuntimeClient(
            sendTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .waitingTool,
                    events: [
                        event(id: "user_1", kind: .userMessage, payload: "use tool debug.echo"),
                        event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                        event(
                            id: "tool_call",
                            kind: .toolCallRequested,
                            payload: #"{"call_id":"call_1","name":"debug.echo","arguments_json":"{\"text\":\"hello\"}","route_state":"ready","route_reason":null}"#
                        ),
                    ],
                    pendingToolCallId: "call_1"
                ),
            ],
            submitTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .completed,
                    events: [
                        event(
                            id: "tool_result",
                            kind: .toolResultMessage,
                            payload: #"{"type":"tool_result","display_text":"Echo: hello","model_text":"debug.echo: hello","structured_json":"{\"text\":\"hello\"}","audit_text":"debug.echo executed","sensitivity":"public","retention":"run_only","is_error":false}"#
                        ),
                        event(id: "delta_1", kind: .assistantTextDelta, payload: "Mock response "),
                        event(id: "delta_2", kind: .assistantTextDelta, payload: "after tool: debug.echo: hello"),
                        event(
                            id: "completed",
                            kind: .assistantMessageCompleted,
                            payload: "Mock response after tool: debug.echo: hello"
                        ),
                    ],
                    pendingToolCallId: nil
                ),
            ],
            pendingToolRequests: [
                ToolExecutionRequestDTO(
                    runId: "run_1",
                    sessionId: "session_1",
                    toolCallEntryId: "tool_call",
                    toolCallId: "call_1",
                    toolName: "debug.echo",
                    argumentsJson: #"{"text":"hello"}"#
                ),
            ]
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state = try await service.sendMessage("use tool debug.echo", state: state)

        #expect(await client.submittedToolResults.count == 1)
        #expect(await client.submittedToolResults.first?.result.modelText == "debug.echo: hello")
        #expect(state.messages.map(\.text).contains("Echo: hello"))
        #expect(state.messages.map(\.text).contains("Mock response after tool: debug.echo: hello"))
    }

    private func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String,
        runId: String = "run_1"
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor BlockingSendRuntimeClient: RuntimeClient {
    private var sendContinuation: CheckedContinuation<AgentTurnResultDTO, Never>?
    private var sendStartedContinuation: CheckedContinuation<Void, Never>?

    private(set) var sentMessages: [ScriptedRuntimeClient.SentMessage] = []

    func waitForSendStarted() async {
        if !sentMessages.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            sendStartedContinuation = continuation
        }
    }

    func completeSend(with turn: AgentTurnResultDTO) {
        sendContinuation?.resume(returning: turn)
        sendContinuation = nil
    }

    func createSession() async throws -> String {
        "session_1"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        sentMessages.append(ScriptedRuntimeClient.SentMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text
        ))
        sendStartedContinuation?.resume()
        sendStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            sendContinuation = continuation
        }
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        AgentTurnResultDTO(runId: runId, state: .completed, events: [], pendingToolCallId: nil)
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        AgentTurnResultDTO(runId: "run_1", state: .completed, events: [], pendingToolCallId: nil)
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: "cancelled",
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: 1,
            depth: 0,
            kind: .runCancelled,
            payload: "cancelled",
            blobRefs: []
        )
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }
}

private actor ScriptedRuntimeClient: RuntimeClient {
    struct SentMessage: Equatable, Sendable {
        var sessionId: String
        var parentEventId: String?
        var text: String
    }

    struct SubmittedToolResult: Sendable {
        var runId: String
        var result: ToolResultDTO
    }

    private var sessionCount = 0
    private var sendTurns: [AgentTurnResultDTO]
    private var submitTurns: [AgentTurnResultDTO]
    private var pendingRequests: [ToolExecutionRequestDTO]

    private(set) var registeredToolSchemas: [ToolSchemaDTO] = []
    private(set) var sentMessages: [SentMessage] = []
    private(set) var submittedToolResults: [SubmittedToolResult] = []

    init(
        sendTurns: [AgentTurnResultDTO] = [],
        submitTurns: [AgentTurnResultDTO] = [],
        pendingToolRequests: [ToolExecutionRequestDTO] = []
    ) {
        self.sendTurns = sendTurns
        self.submitTurns = submitTurns
        self.pendingRequests = pendingToolRequests
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        guard sessionCount > 0 else {
            return []
        }
        return (1...sessionCount).map { "session_\($0)" }
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {
        registeredToolSchemas.append(schema)
    }

    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        sentMessages.append(SentMessage(sessionId: sessionId, parentEventId: parentEventId, text: text))
        return sendTurns.removeFirst()
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        pendingRequests
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        submittedToolResults.append(SubmittedToolResult(runId: runId, result: result))
        pendingRequests.removeAll { $0.runId == runId }
        return submitTurns.removeFirst()
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        submitTurns.removeFirst()
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: "cancelled",
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: 1,
            depth: 0,
            kind: .runCancelled,
            payload: "cancelled",
            blobRefs: []
        )
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }
}
