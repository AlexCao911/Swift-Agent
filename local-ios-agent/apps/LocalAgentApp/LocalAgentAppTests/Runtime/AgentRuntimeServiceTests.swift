import Foundation
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

    @Test("prepare loads provider profiles and active provider")
    func prepareLoadsProviderProfilesAndActiveProvider() async throws {
        let client = ScriptedRuntimeClient()
        await client.setProviderProfilesForTest([
            ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096),
            ProviderProfileDTO(id: "local_llm", displayName: "Local LLM", kind: .localLLM, maxContextTokens: 2048),
        ])
        await client.setActiveProviderForTest(
            ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096)
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.prepare()

        #expect(state.provider.profiles.map(\.id) == ["mock", "local_llm"])
        #expect(state.provider.active?.id == "mock")
    }

    @Test("select provider updates active provider")
    func selectProviderUpdatesActiveProvider() async throws {
        let client = ScriptedRuntimeClient()
        await client.setProviderProfilesForTest([
            ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096),
            ProviderProfileDTO(id: "local_llm", displayName: "Local LLM", kind: .localLLM, maxContextTokens: 2048),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let prepared = try await service.prepare()

        let state = try await service.selectProvider("local_llm", state: prepared)

        #expect(await client.selectedProviders.map(\.providerId) == ["local_llm"])
        #expect(state.provider.active?.id == "local_llm")
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

    @Test("streamed delta is delivered before final turn result")
    func streamedDeltaIsDeliveredBeforeFinalTurnResult() async throws {
        let client = StreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let observation = StreamObservation()

        let prepared = try await service.prepare()
        async let finalState = service.sendMessage("hello", state: prepared) { event in
            if event.kind == .assistantTextDelta {
                await observation.observeDelta()
            }
        }

        await observation.waitForDelta()
        #expect(await client.didReleaseFinalResult == false)

        await client.releaseFinalResult()
        let state = try await finalState

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text) == ["hello", "hello world"])
    }

    @Test("buffered structured delta is delivered before another stream event arrives")
    func bufferedStructuredDeltaIsDeliveredBeforeAnotherStreamEventArrives() async throws {
        let client = BufferedStreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let observation = StreamObservation()

        let prepared = try await service.prepare()
        async let finalState = service.sendMessage("hello", state: prepared) { event in
            if event.kind == .assistantTextDelta {
                await observation.observeDelta()
            }
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await observation.didObserveDeltaValue)
        #expect(await client.didReleaseFinalResult == false)

        await client.releaseFinalResult()
        let state = try await finalState

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text) == ["hello", "hello world"])
    }

    @Test("structured stream deltas are coalesced before final turn replay")
    func structuredStreamDeltasAreCoalescedBeforeFinalTurnReplay() async throws {
        let client = CoalescingStreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let recorder = StreamEventRecorder()

        let prepared = try await service.prepare()
        let state = try await service.sendMessage("hello", state: prepared) { event in
            await recorder.record(event)
        }

        let observedEvents = await recorder.events
        let observedDeltas = observedEvents.filter { $0.kind == .assistantTextDelta }
        let payload = try #require(observedDeltas.first?.payload)
        let payloadObject = try #require(jsonObject(from: payload))

        #expect(observedDeltas.count == 1)
        #expect(payloadObject["message_id"] == "assistant_1")
        #expect(payloadObject["text"] == "Hello")
        #expect(state.messages.count == 2)
        #expect(state.messages.map(\.text) == ["hello", "Hello!"])
        #expect(state.lastTerminalReason == .completed)
    }

    @Test("failed stream result marks partial output failed without terminal event")
    func failedStreamResultMarksPartialOutputFailedWithoutTerminalEvent() async throws {
        let client = TerminalResultStreamingRuntimeClientProbe(resultState: .failed)
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let prepared = try await service.prepare()
        let state = try await service.sendMessage("hello", state: prepared)

        #expect(state.phase == .failed(message: "Run failed."))
        #expect(state.errorMessage == "Run failed.")
        #expect(state.lastTerminalReason == .failed("Run failed."))
        #expect(state.messages.map(\.text) == ["hello", "partial"])
        #expect(state.messages[1].streaming == .failed("Run failed."))
    }

    @Test("cancelled stream result marks partial output cancelled without terminal event")
    func cancelledStreamResultMarksPartialOutputCancelledWithoutTerminalEvent() async throws {
        let client = TerminalResultStreamingRuntimeClientProbe(resultState: .cancelled)
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let prepared = try await service.prepare()
        let state = try await service.sendMessage("hello", state: prepared)

        #expect(state.phase == .ready)
        #expect(state.lastTerminalReason == .cancelled)
        #expect(state.messages.map(\.text) == ["hello", "partial"])
        #expect(state.messages[1].streaming == .cancelled)
    }

    @Test("stream event failure flushes buffered partial output before throwing")
    func streamEventFailureFlushesBufferedPartialOutputBeforeThrowing() async throws {
        let client = ThrowingStreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let recorder = StreamEventRecorder()

        let prepared = try await service.prepare()
        do {
            _ = try await service.sendMessage("hello", state: prepared) { event in
                await recorder.record(event)
            }
            Issue.record("Expected stream failure")
        } catch is RuntimeStreamProbeError {
        }

        let observedEvents = await recorder.events
        let observedDeltas = observedEvents.filter { $0.kind == .assistantTextDelta }
        let payload = try #require(observedDeltas.first?.payload)
        let payloadObject = try #require(jsonObject(from: payload))
        #expect(observedDeltas.count == 1)
        #expect(payloadObject["text"] == "partial")
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

    @Test("continuation limit submits an error tool result to finish the run")
    func continuationLimitSubmitsErrorToolResultToFinishRun() async throws {
        let client = ScriptedRuntimeClient(
            sendTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .waitingTool,
                    events: [
                        event(id: "user_1", kind: .userMessage, payload: "use tool debug.echo"),
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
                            payload: #"{"type":"tool_result","display_text":"Tool stopped: continuation limit exceeded.","model_text":"debug.echo stopped: continuation limit exceeded.","structured_json":"{\"error\":\"continuation_limit_exceeded\",\"tool_name\":\"debug.echo\"}","audit_text":"Stopped debug.echo: continuation limit exceeded.","sensitivity":"public","retention":"run_only","is_error":true}"#
                        ),
                        event(
                            id: "completed",
                            kind: .assistantMessageCompleted,
                            payload: "Mock response after tool: debug.echo stopped: continuation limit exceeded."
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
        let service = AgentRuntimeService(
            runtimeClient: client,
            toolDriver: MinimalHostToolDriver(maxContinuations: 0)
        )

        var state = try await service.prepare()
        state = try await service.sendMessage("use tool debug.echo", state: state)

        #expect(await client.submittedToolResults.count == 1)
        #expect(await client.submittedToolResults.first?.result.isError == true)
        #expect(await client.submittedToolResults.first?.result.structuredJson.contains("continuation_limit_exceeded") == true)
        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("Tool stopped: continuation limit exceeded."))
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

    private func jsonObject(from payload: String) -> [String: String]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return nil
        }
        return object
    }
}

private actor StreamObservation {
    private var didObserveDelta = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var didObserveDeltaValue: Bool {
        didObserveDelta
    }

    func observeDelta() {
        didObserveDelta = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func waitForDelta() async {
        if didObserveDelta {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor StreamEventRecorder {
    private(set) var events: [RuntimeEventDTO] = []

    func record(_ event: RuntimeEventDTO) {
        events.append(event)
    }
}

private actor StreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0
    private var finalResultContinuation: CheckedContinuation<Void, Never>?
    private var releasedFinalResult = false

    var didReleaseFinalResult: Bool {
        releasedFinalResult
    }

    func releaseFinalResult() {
        releasedFinalResult = true
        finalResultContinuation?.resume()
        finalResultContinuation = nil
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task<AgentTurnResultDTO, any Error> {
            continuation.yield(Self.event(id: "user_1", kind: .userMessage, payload: text))
            continuation.yield(Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"))
            continuation.yield(Self.event(id: "delta_1", kind: .assistantTextDelta, payload: "hello "))
            await self.waitForFinalRelease()
            continuation.yield(Self.event(id: "completed", kind: .assistantMessageCompleted, payload: "hello world"))
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    Self.event(id: "user_1", kind: .userMessage, payload: text),
                    Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                    Self.event(id: "delta_1", kind: .assistantTextDelta, payload: "hello "),
                    Self.event(id: "completed", kind: .assistantMessageCompleted, payload: "hello world"),
                ],
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private func waitForFinalRelease() async {
        if releasedFinalResult {
            return
        }
        await withCheckedContinuation { continuation in
            finalResultContinuation = continuation
        }
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor BufferedStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0
    private var finalResultContinuation: CheckedContinuation<Void, Never>?
    private var releasedFinalResult = false

    var didReleaseFinalResult: Bool {
        releasedFinalResult
    }

    func releaseFinalResult() {
        releasedFinalResult = true
        finalResultContinuation?.resume()
        finalResultContinuation = nil
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task<AgentTurnResultDTO, any Error> {
            continuation.yield(Self.event(id: "user_1", kind: .userMessage, payload: text))
            continuation.yield(Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#))
            continuation.yield(Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"hello "}"#))
            await self.waitForFinalRelease()
            continuation.yield(Self.event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"hello world"}"#))
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    Self.event(id: "user_1", kind: .userMessage, payload: text),
                    Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
                    Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"hello "}"#),
                    Self.event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"hello world"}"#),
                ],
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private func waitForFinalRelease() async {
        if releasedFinalResult {
            return
        }
        await withCheckedContinuation { continuation in
            finalResultContinuation = continuation
        }
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor CoalescingStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let streamedEvents = [
            Self.event(id: "user_1", kind: .userMessage, payload: text),
            Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"Hel"}"#),
            Self.event(id: "delta_2", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"lo"}"#),
            Self.event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"Hello!"}"#),
        ]
        let result = Task<AgentTurnResultDTO, any Error> {
            for event in streamedEvents {
                continuation.yield(event)
            }
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: streamedEvents,
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor TerminalResultStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private let resultState: RunStateDTO
    private var sessionCount = 0

    init(resultState: RunStateDTO) {
        self.resultState = resultState
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let streamedEvents = [
            Self.event(id: "user_1", kind: .userMessage, payload: text),
            Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"partial"}"#),
        ]
        let state = resultState
        let result = Task<AgentTurnResultDTO, any Error> {
            for event in streamedEvents {
                continuation.yield(event)
            }
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: state,
                events: streamedEvents,
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private enum RuntimeStreamProbeError: Error {
    case streamStopped
}

private actor ThrowingStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task<AgentTurnResultDTO, any Error> {
            continuation.yield(Self.event(id: "user_1", kind: .userMessage, payload: text))
            continuation.yield(Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#))
            continuation.yield(Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"partial"}"#))
            continuation.finish(throwing: RuntimeStreamProbeError.streamStopped)
            throw RuntimeStreamProbeError.streamStopped
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
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

private actor ScriptedRuntimeClient: RuntimeClient, ProviderControllingRuntimeClient {
    struct SentMessage: Equatable, Sendable {
        var sessionId: String
        var parentEventId: String?
        var text: String
    }

    struct SubmittedToolResult: Sendable {
        var runId: String
        var result: ToolResultDTO
    }

    struct SelectedProvider: Equatable, Sendable {
        var sessionId: String
        var providerId: String
    }

    private var sessionCount = 0
    private var sendTurns: [AgentTurnResultDTO]
    private var submitTurns: [AgentTurnResultDTO]
    private var pendingRequests: [ToolExecutionRequestDTO]
    private var providerProfilesForTest: [ProviderProfileDTO]
    private var activeProviderForTest: ProviderProfileDTO

    private(set) var registeredToolSchemas: [ToolSchemaDTO] = []
    private(set) var sentMessages: [SentMessage] = []
    private(set) var submittedToolResults: [SubmittedToolResult] = []
    private(set) var selectedProviders: [SelectedProvider] = []

    init(
        sendTurns: [AgentTurnResultDTO] = [],
        submitTurns: [AgentTurnResultDTO] = [],
        pendingToolRequests: [ToolExecutionRequestDTO] = []
    ) {
        self.sendTurns = sendTurns
        self.submitTurns = submitTurns
        self.pendingRequests = pendingToolRequests
        self.providerProfilesForTest = [
            ProviderProfileDTO(
                id: "mock",
                displayName: "Mock",
                kind: .mock,
                maxContextTokens: 100
            ),
        ]
        self.activeProviderForTest = providerProfilesForTest[0]
    }

    func setProviderProfilesForTest(_ profiles: [ProviderProfileDTO]) {
        providerProfilesForTest = profiles
        if activeProviderForTest.id.isEmpty || !profiles.contains(where: { $0.id == activeProviderForTest.id }) {
            activeProviderForTest = profiles[0]
        }
    }

    func setActiveProviderForTest(_ profile: ProviderProfileDTO) {
        activeProviderForTest = profile
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

    func providerProfiles() async throws -> [ProviderProfileDTO] {
        providerProfilesForTest
    }

    func activeProvider() async throws -> ProviderProfileDTO {
        activeProviderForTest
    }

    func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO {
        selectedProviders.append(SelectedProvider(sessionId: sessionId, providerId: providerId))
        if let profile = providerProfilesForTest.first(where: { $0.id == providerId }) {
            activeProviderForTest = profile
        }
        return RuntimeEventDTO(
            id: "provider_changed",
            sessionId: sessionId,
            parentId: nil,
            runId: nil,
            sequence: 1,
            depth: 0,
            kind: .providerChanged,
            payload: #"{"provider_id":"\#(providerId)"}"#,
            blobRefs: []
        )
    }
}
