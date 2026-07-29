import LocalAgentLLMContracts
import Testing
@testable import LocalAgentApp

@Suite("OpenMinis product diagnostics")
struct OpenMinisProductBenchmarkTests {
    @Test("diagnostics preserve milestone order and report no leaked tools")
    func diagnosticsPreserveOrderAndReportNoLeaks() async throws {
        let trace = OpenMinisAgentRequestTrace(runID: "benchmark-run")
        let dispatcher = DiagnosticToolDispatcher(trace: trace)
        let executor = OpenMinisToolBatchExecutor(
            dispatcher: dispatcher,
            definitions: try OpenMinisToolDefinitionSnapshotProvider.productDefaults()
        )

        trace.requestStarted()
        trace.firstVisibleEvent()
        trace.toolBatchStarted()
        let completion = await executor.execute(HostToolBatch(
            batchID: "benchmark-batch",
            runID: "benchmark-run",
            orderedCalls: [
                HostToolCall(
                    callID: "first",
                    toolName: "shell_execute",
                    argumentsJSON: #"{"command":"printf first"}"#
                ),
                HostToolCall(
                    callID: "second",
                    toolName: "shell_execute",
                    argumentsJSON: #"{"command":"printf second"}"#
                ),
            ]
        ))
        trace.toolBatchCompleted()
        trace.projectionCompleted()
        await executor.cancel(batchID: "benchmark-batch")
        trace.cancellationCleanedUp()

        let snapshot = trace.snapshot()
        #expect(completion.orderedResults.map(\.callID) == ["first", "second"])
        #expect(snapshot.milestones == [
            .requestStarted,
            .firstVisibleEvent,
            .toolBatchStarted,
            .toolBatchCompleted,
            .projectionCompleted,
            .cancellationCleanedUp,
        ])
        #expect(snapshot.firstVisibleEventNanoseconds != nil)
        #expect(snapshot.toolBatchDurationNanoseconds != nil)
        #expect(snapshot.projectionCompletionNanoseconds != nil)
        #expect(snapshot.cancellationCleanupNanoseconds != nil)
        #expect(snapshot.peakActiveToolProcesses == 2)
        #expect(snapshot.activeToolProcesses == 0)
    }
}

private actor DiagnosticToolDispatcher: OpenMinisToolDispatching {
    private let trace: OpenMinisAgentRequestTrace

    init(trace: OpenMinisAgentRequestTrace) {
        self.trace = trace
    }

    func execute(
        _ call: HostToolCall,
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        trace.toolProcessStarted()
        await context.onProcessStarted(call.callID == "first" ? 1 : 2)
        try? await Task.sleep(for: .milliseconds(20))
        trace.toolProcessFinished()
        return HostToolResult(
            callID: call.callID,
            toolName: call.toolName,
            result: .string("ok"),
            isError: false,
            dataClasses: [],
            highestSensitivity: "public"
        )
    }

    func cancel(processID _: Int32) async {}
}
