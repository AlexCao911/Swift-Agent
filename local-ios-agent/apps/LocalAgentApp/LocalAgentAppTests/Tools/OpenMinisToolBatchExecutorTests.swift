import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentApp

@Suite("OpenMinis tool batch executor")
struct OpenMinisToolBatchExecutorTests {
    @Test
    func executesAtMostTenConcurrentlyAndReturnsInputOrder() async throws {
        let dispatcher = BatchDispatcherProbe()
        let executor = try makeExecutor(dispatcher: dispatcher)
        let calls = (0..<14).map { index in
            HostToolCall(
                callID: "call-\(index)",
                toolName: "shell_execute",
                argumentsJSON: #"{"command":"echo \#(index)","tool_title":"Run \#(index)"}"#
            )
        }

        let completion = await executor.execute(
            HostToolBatch(batchID: "batch", runID: "run", orderedCalls: calls)
        )

        #expect(await dispatcher.maximumActive == 10)
        #expect(completion.batchID == "batch")
        #expect(completion.runID == "run")
        #expect(completion.orderedResults.map(\.callID) == calls.map(\.callID))
        #expect(completion.orderedResults.allSatisfy { $0.isError == false })
    }

    @Test
    func unknownToolReturnsOrderedErrorWithoutDispatch() async throws {
        let dispatcher = BatchDispatcherProbe()
        let executor = try makeExecutor(dispatcher: dispatcher)
        let completion = await executor.execute(
            HostToolBatch(
                batchID: "batch",
                runID: "run",
                orderedCalls: [
                    HostToolCall(
                        callID: "unknown",
                        toolName: "missing_tool",
                        argumentsJSON: "{}"
                    ),
                ]
            )
        )

        #expect(completion.orderedResults.count == 1)
        #expect(completion.orderedResults[0].isError)
        #expect(completion.orderedResults[0].toolName == "missing_tool")
        #expect(await dispatcher.startedCallIDs.isEmpty)
    }

    @Test
    func sameCallIDInTwoBatchesHasIndependentCancellation() async throws {
        let dispatcher = BatchDispatcherProbe(delayNanoseconds: 200_000_000)
        let executor = try makeExecutor(dispatcher: dispatcher)
        let call = HostToolCall(
            callID: "same",
            toolName: "shell_execute",
            argumentsJSON: #"{"command":"echo ok","tool_title":"Run command"}"#
        )
        let first = Task {
            await executor.execute(
                HostToolBatch(batchID: "batch-a", runID: "run-a", orderedCalls: [call])
            )
        }
        let second = Task {
            await executor.execute(
                HostToolBatch(batchID: "batch-b", runID: "run-b", orderedCalls: [call])
            )
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        await executor.cancel(batchID: "batch-a")
        let firstCompletion = await first.value
        let secondCompletion = await second.value

        #expect(firstCompletion.orderedResults[0].isError)
        #expect(secondCompletion.orderedResults[0].isError == false)
    }

    @Test
    func detectorHistoryIsScopedToRunAndRemovedAtRunEnd() async throws {
        let executor = try makeExecutor(dispatcher: BatchDispatcherProbe())

        _ = await executor.execute(
            HostToolBatch(batchID: "a", runID: "run-a", orderedCalls: [])
        )
        _ = await executor.execute(
            HostToolBatch(batchID: "b", runID: "run-b", orderedCalls: [])
        )
        #expect(executor.hasLoopDetector(runID: "run-a"))
        #expect(executor.hasLoopDetector(runID: "run-b"))

        await executor.finish(runID: "run-a")

        #expect(executor.hasLoopDetector(runID: "run-a") == false)
        #expect(executor.hasLoopDetector(runID: "run-b"))
    }

    @Test
    func repairsOneCharacterFieldTypoBeforeDispatch() async throws {
        let dispatcher = BatchDispatcherProbe()
        let executor = try makeExecutor(dispatcher: dispatcher)

        let completion = await executor.execute(
            HostToolBatch(
                batchID: "batch",
                runID: "run",
                orderedCalls: [
                    HostToolCall(
                        callID: "repair",
                        toolName: "shell_execute",
                        argumentsJSON: #"{"comand":"echo repaired"}"#
                    ),
                ]
            )
        )

        #expect(completion.orderedResults[0].isError == false)
        let received = await dispatcher.receivedArgumentsJSON
        #expect(received.count == 1)
        #expect(received[0].contains(#""command":"echo repaired""#))
    }

    @Test
    func fileEditAllowsEmptyNewString() async throws {
        let dispatcher = BatchDispatcherProbe()
        let executor = try makeExecutor(dispatcher: dispatcher)

        let completion = await executor.execute(
            HostToolBatch(
                batchID: "batch",
                runID: "run",
                orderedCalls: [
                    HostToolCall(
                        callID: "delete",
                        toolName: "file_edit",
                        argumentsJSON: #"{"path":"/tmp/note","old_string":"remove","new_string":""}"#
                    ),
                ]
            )
        )

        #expect(completion.orderedResults[0].isError == false)
    }

    @Test
    func nativeSchemasJoinTheSameOrderedCatalog() throws {
        let provider = try OpenMinisToolDefinitionSnapshotProvider.productDefaults(
            nativeSchemas: [
                ToolSchemaDTO(
                    name: "calendar.search_events",
                    description: "Search calendar events.",
                    parametersJsonSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#,
                    riskLevel: .readOnly
                ),
            ]
        )

        #expect(provider.orderedDefinitions.last?.name == "calendar.search_events")
        #expect(
            provider.definition(named: "calendar.search_events")?.requiredFields
                == ["query"]
        )
    }

    @Test
    func browserSchemaExposesEveryImplementedInput() throws {
        let provider = try OpenMinisToolDefinitionSnapshotProvider.productDefaults()
        let properties = provider.definition(named: "browser_use")?
            .inputSchema
            .objectValue(forKey: "properties")?
            .objectKeys

        #expect(properties?.contains("coordinate_x") == true)
        #expect(properties?.contains("cookies") == true)
        #expect(properties?.contains("viewport_width") == true)
        #expect(properties?.contains("full_page") == true)
    }

    private func makeExecutor(
        dispatcher: BatchDispatcherProbe
    ) throws -> OpenMinisToolBatchExecutor {
        OpenMinisToolBatchExecutor(
            dispatcher: dispatcher,
            definitions: try OpenMinisToolDefinitionSnapshotProvider.productDefaults()
        )
    }
}

private actor BatchDispatcherProbe: OpenMinisToolDispatching {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var startedCallIDs: [String] = []
    private(set) var receivedArgumentsJSON: [String] = []
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 20_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(
        _ call: HostToolCall,
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult {
        active += 1
        maximumActive = max(maximumActive, active)
        startedCallIDs.append("\(context.batchID):\(call.callID)")
        receivedArgumentsJSON.append(call.argumentsJSON)
        defer { active -= 1 }
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
            return HostToolResult(
                callID: call.callID,
                toolName: call.toolName,
                result: .string(call.callID),
                isError: false,
                dataClasses: [],
                highestSensitivity: "public"
            )
        } catch {
            return HostToolResult(
                callID: call.callID,
                toolName: call.toolName,
                result: .string("cancelled"),
                isError: true,
                dataClasses: [],
                highestSensitivity: "public"
            )
        }
    }

    func cancel(processID: Int32) async {}
}
