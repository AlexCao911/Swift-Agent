import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMHost

@Suite("Tool batch execution contract")
struct ToolBatchExecutingContractTests {
    @Test
    func batchRoundTripsWithStableOrderedCallsAndIdentity() throws {
        let batch = HostToolBatch(
            batchID: "batch-1",
            runID: "run-1",
            orderedCalls: (0..<10).map { index in
                HostToolCall(
                    callID: "call-\(index)",
                    toolName: "shell",
                    argumentsJSON: #"{"index":\#(index)}"#
                )
            }
        )

        let encoded = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(HostToolBatch.self, from: encoded)

        #expect(decoded == batch)
        #expect(decoded.batchID == "batch-1")
        #expect(decoded.runID == "run-1")
        #expect(decoded.orderedCalls.map(\.callID) == (0..<10).map { "call-\($0)" })
    }

    @Test
    func completionEchoesBatchAndRunIdentityInStableOrder() async {
        let executor = EchoToolBatchExecutor()
        let batch = HostToolBatch(
            batchID: "batch-2",
            runID: "run-2",
            orderedCalls: [
                HostToolCall(callID: "same", toolName: "first", argumentsJSON: "{}"),
                HostToolCall(callID: "same", toolName: "second", argumentsJSON: "{}"),
            ]
        )

        let completion = await executor.execute(batch)

        #expect(completion.batchID == batch.batchID)
        #expect(completion.runID == batch.runID)
        #expect(completion.orderedResults.map(\.toolName) == ["first", "second"])
    }
}

private struct EchoToolBatchExecutor: ToolBatchExecuting {
    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion {
        HostToolBatchCompletion(
            batchID: batch.batchID,
            runID: batch.runID,
            orderedResults: batch.orderedCalls.map { call in
                HostToolResult(
                    callID: call.callID,
                    toolName: call.toolName,
                    result: .null,
                    isError: false,
                    dataClasses: [],
                    highestSensitivity: "public"
                )
            }
        )
    }

    func cancel(batchID: String) async {}
}
