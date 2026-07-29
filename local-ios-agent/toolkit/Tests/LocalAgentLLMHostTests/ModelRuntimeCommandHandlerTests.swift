import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMHost

@Suite("Model runtime command handler")
struct ModelRuntimeCommandHandlerTests {
    @Test
    func oneRequestUsesOneExecutorAndOneSequencedEventPath() async throws {
        let executor = RecordingModelExecutor()
        let submitter = HandlerEventSubmitter()
        let sequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: handlerEpoch,
            submitter: submitter
        )
        let handler = ModelRuntimeCommandHandler(executor: executor)

        await handler.generate(
            request: modelRequest,
            generationTurnID: "turn-1",
            sequencer: sequencer
        )

        #expect(await executor.requestCount() == 1)
        let events = await submitter.events()
        #expect(events.map(\.kind) == [
            .generationStarted,
            .textDelta,
            .reasoningSummaryDelta,
            .toolCallStarted,
            .toolCallArgumentsDelta,
            .toolCallArgumentsDelta,
            .usageUpdated,
            .toolCallCompleted,
            .generationCompleted,
        ])
        #expect(events.last?.payload.completion?.outcome == "tool_calls_ready")
        #expect(events.last?.payload.completion?.orderedCallIDs == ["call-1"])
    }

    @Test
    func cancellationRoutesOnlyToTheModelExecutor() async {
        let executor = RecordingModelExecutor()
        let handler = ModelRuntimeCommandHandler(executor: executor)

        await handler.cancel(runID: "run-2")

        #expect(await executor.cancelledRuns() == ["run-2"])
    }
}

private let handlerEpoch = HostProcessEpoch(
    rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
)!

private let modelRequest = HostModelRequest(
    runID: "run-1",
    conversationStreamID: "conversation-1",
    systemPrompt: "system",
    orderedMessages: [],
    attachmentReferences: [],
    orderedToolDefinitions: []
)

private actor RecordingModelExecutor: ModelGenerationExecuting {
    private var requests: [HostModelRequest] = []
    private var cancellations: [String] = []

    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws {
        requests.append(request)
        try await emit(.textDelta("hello"))
        try await emit(.reasoningDelta("thinking"))
        try await emit(.toolCallDelta(
            callID: "call-1",
            toolName: "shell",
            argumentsFragment: #"{"command":"#
        ))
        try await emit(.toolCallDelta(
            callID: "call-1",
            toolName: "shell",
            argumentsFragment: #""pwd"}"#
        ))
        try await emit(.usage(try .object(entries: [
            CanonicalJSONObjectEntry(name: "input_tokens", value: .number(12)),
            CanonicalJSONObjectEntry(name: "output_tokens", value: .number(7)),
        ])))
    }

    func cancel(runID: String) async {
        cancellations.append(runID)
    }

    func requestCount() -> Int { requests.count }
    func cancelledRuns() -> [String] { cancellations }
}

private actor HandlerEventSubmitter: LLMEventSubmitting {
    private var submitted: [LLMEventEnvelope] = []

    func submit(_ envelope: LLMEventEnvelope) async throws -> LLMEventSubmissionResult {
        submitted.append(envelope)
        return .accepted
    }

    func events() -> [LLMEventEnvelope] { submitted }
}
