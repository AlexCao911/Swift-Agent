import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMHost

struct OpenMinisToolExecutionContext: Sendable {
    let batchID: String
    let runID: String
    let onProcessStarted: @Sendable (Int32) async -> Void
}

protocol OpenMinisToolDispatching: Sendable {
    func execute(
        _ call: HostToolCall,
        context: OpenMinisToolExecutionContext
    ) async -> HostToolResult

    func cancel(processID: Int32) async
}

final class OpenMinisToolBatchExecutor: ToolBatchExecuting, @unchecked Sendable {
    static let maximumConcurrentTools = 10

    private let dispatcher: any OpenMinisToolDispatching
    private let definitions: OpenMinisToolDefinitionSnapshotProvider
    private let cancellationRegistry: ToolCallCancellationRegistry
    private let detectorRegistry: ToolLoopDetectorRegistry

    init(
        dispatcher: any OpenMinisToolDispatching,
        definitions: OpenMinisToolDefinitionSnapshotProvider,
        detectorRegistry: ToolLoopDetectorRegistry = ToolLoopDetectorRegistry()
    ) {
        self.dispatcher = dispatcher
        self.definitions = definitions
        self.detectorRegistry = detectorRegistry
        self.cancellationRegistry = ToolCallCancellationRegistry { processID in
            await dispatcher.cancel(processID: processID)
        }
    }

    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion {
        await cancellationRegistry.beginBatch(
            batchID: batch.batchID,
            runID: batch.runID
        )
        let detector = detectorRegistry.detector(for: batch.runID)
        var orderedResults: [HostToolResult] = []
        orderedResults.reserveCapacity(batch.orderedCalls.count)

        for start in stride(
            from: 0,
            to: batch.orderedCalls.count,
            by: Self.maximumConcurrentTools
        ) {
            let end = min(
                start + Self.maximumConcurrentTools,
                batch.orderedCalls.count
            )
            let slice = Array(batch.orderedCalls[start..<end])
            let chunkResults = await executeChunk(
                slice,
                batch: batch,
                detector: detector
            )
            orderedResults.append(contentsOf: chunkResults)
        }

        recordDetectorHistoryInInputOrder(
            calls: batch.orderedCalls,
            results: orderedResults,
            detector: detector
        )
        await cancellationRegistry.finishBatch(batchID: batch.batchID)
        return HostToolBatchCompletion(
            batchID: batch.batchID,
            runID: batch.runID,
            orderedResults: orderedResults
        )
    }

    func cancel(batchID: String) async {
        await cancellationRegistry.cancel(batchID: batchID)
    }

    func finish(runID: String) {
        detectorRegistry.remove(runID: runID)
    }

    func hasLoopDetector(runID: String) -> Bool {
        detectorRegistry.contains(runID: runID)
    }

    private func executeChunk(
        _ calls: [HostToolCall],
        batch: HostToolBatch,
        detector: ToolLoopDetector
    ) async -> [HostToolResult] {
        await withTaskGroup(
            of: IndexedToolResult.self,
            returning: [HostToolResult].self
        ) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { [self] in
                    let result = await executeOne(
                        call,
                        batch: batch,
                        detector: detector
                    )
                    return IndexedToolResult(index: index, result: result)
                }
            }

            var indexed: [IndexedToolResult] = []
            indexed.reserveCapacity(calls.count)
            for await result in group {
                indexed.append(result)
            }
            return indexed.sorted { $0.index < $1.index }.map(\.result)
        }
    }

    private func executeOne(
        _ call: HostToolCall,
        batch: HostToolBatch,
        detector: ToolLoopDetector
    ) async -> HostToolResult {
        guard let definition = definitions.definition(named: call.toolName) else {
            return errorResult(
                call,
                message: "Unknown tool '\(call.toolName)'. Do not retry this unavailable tool."
            )
        }
        guard let arguments = OpenMinisToolArgumentRepair.repair(
            rawJSON: call.argumentsJSON,
            definition: definition
        ) else {
            return errorResult(call, message: "Tool arguments must be a JSON object.")
        }
        let enforcedRequiredFields = definition.requiredFields.filter {
            $0 != "tool_title"
        }
        let missing = enforcedRequiredFields.filter { field in
            guard let value = arguments[field], value is NSNull == false else {
                return true
            }
            if let text = value as? String {
                return text.isEmpty
                    && !(call.toolName == "file_edit" && field == "new_string")
            }
            return false
        }
        guard missing.isEmpty else {
            return errorResult(
                call,
                message: "Missing required tool arguments: \(missing.joined(separator: ", "))."
            )
        }

        let loopCheck = detector.check(toolName: call.toolName, params: arguments)
        if loopCheck.level == .critical {
            return errorResult(
                call,
                message: loopCheck.message ?? "Tool execution blocked by loop detector."
            )
        }

        guard let repairedJSON = OpenMinisToolArgumentRepair.encode(arguments) else {
            return errorResult(call, message: "Tool arguments cannot be encoded.")
        }
        let repairedCall = HostToolCall(
            callID: call.callID,
            toolName: call.toolName,
            argumentsJSON: repairedJSON
        )
        let task = Task { [dispatcher, cancellationRegistry] in
            await dispatcher.execute(
                repairedCall,
                context: OpenMinisToolExecutionContext(
                    batchID: batch.batchID,
                    runID: batch.runID,
                    onProcessStarted: { processID in
                        await cancellationRegistry.record(
                            pid: processID,
                            batchID: batch.batchID,
                            callID: call.callID
                        )
                    }
                )
            )
        }
        await cancellationRegistry.register(
            batchID: batch.batchID,
            callID: call.callID,
            runID: batch.runID
        ) {
            task.cancel()
        }
        return await task.value
    }

    private func recordDetectorHistoryInInputOrder(
        calls: [HostToolCall],
        results: [HostToolResult],
        detector: ToolLoopDetector
    ) {
        for (call, result) in zip(calls, results) {
            let parameters: [String: Any]
            if let definition = definitions.definition(named: call.toolName),
               let repaired = OpenMinisToolArgumentRepair.repair(
                   rawJSON: call.argumentsJSON,
                   definition: definition
               ) {
                parameters = repaired
            } else {
                parameters = argumentsObject(call.argumentsJSON) ?? [:]
            }
            let resultText = (try? String(
                data: JSONEncoder().encode(result.result),
                encoding: .utf8
            )) ?? ""
            detector.record(
                toolName: call.toolName,
                params: parameters,
                result: result.isError ? nil : resultText,
                errorMessage: result.isError ? resultText : nil,
                toolCallId: call.callID
            )
        }
    }

    private func argumentsObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            return nil
        }
        return object
    }

    private func errorResult(
        _ call: HostToolCall,
        message: String
    ) -> HostToolResult {
        HostToolResult(
            callID: call.callID,
            toolName: call.toolName,
            result: .string(message),
            isError: true,
            dataClasses: [],
            highestSensitivity: "public"
        )
    }
}

private struct IndexedToolResult: Sendable {
    let index: Int
    let result: HostToolResult
}
