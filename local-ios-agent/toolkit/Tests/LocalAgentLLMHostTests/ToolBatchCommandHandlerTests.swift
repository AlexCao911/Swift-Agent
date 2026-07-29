import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMHost

@Suite("Tool batch command handler")
struct ToolBatchCommandHandlerTests {
    @Test
    func completionKeepsBatchRunAndResultOrder() async throws {
        let executor = RecordingToolExecutor()
        let submitter = ToolHandlerEventSubmitter()
        let sequencer = LLMEventSequencer(
            runID: "run-1",
            sessionHandle: "session-1",
            hostProcessEpoch: toolHandlerEpoch,
            submitter: submitter
        )
        let handler = ToolBatchCommandHandler(executor: executor)
        let batch = HostToolBatch(
            batchID: "batch-1",
            runID: "run-1",
            orderedCalls: [
                HostToolCall(callID: "same", toolName: "first", argumentsJSON: "{}"),
                HostToolCall(callID: "same", toolName: "second", argumentsJSON: "{}"),
            ]
        )

        await handler.execute(batch, sequencer: sequencer)

        let events = await submitter.events()
        #expect(events.map(\.kind) == [.toolBatchStarted, .toolBatchCompleted])
        #expect(events.last?.payload.toolBatchCompletion?.batchID == "batch-1")
        #expect(events.last?.payload.toolBatchCompletion?.runID == "run-1")
        #expect(
            events.last?.payload.toolBatchCompletion?.orderedResults.map(\.toolName)
                == ["first", "second"]
        )
    }

    @Test
    func cancellationUsesTheExactBatchID() async {
        let executor = RecordingToolExecutor()
        let handler = ToolBatchCommandHandler(executor: executor)

        await handler.cancel(batchID: "batch-2")

        #expect(await executor.cancelledBatches() == ["batch-2"])
    }
}

private let toolHandlerEpoch = HostProcessEpoch(
    rawValue: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
)!

private actor RecordingToolExecutor: ToolBatchExecuting {
    private var cancellations: [String] = []

    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion {
        HostToolBatchCompletion(
            batchID: batch.batchID,
            runID: batch.runID,
            orderedResults: batch.orderedCalls.map {
                HostToolResult(
                    callID: $0.callID,
                    toolName: $0.toolName,
                    result: .null,
                    isError: false,
                    dataClasses: [],
                    highestSensitivity: "public"
                )
            }
        )
    }

    func cancel(batchID: String) async {
        cancellations.append(batchID)
    }

    func cancelledBatches() -> [String] { cancellations }
}

private actor ToolHandlerEventSubmitter: LLMEventSubmitting {
    private var submitted: [LLMEventEnvelope] = []

    func submit(_ envelope: LLMEventEnvelope) async throws -> LLMEventSubmissionResult {
        submitted.append(envelope)
        return .accepted
    }

    func events() -> [LLMEventEnvelope] { submitted }
}
