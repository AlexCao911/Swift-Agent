import LocalAgentLLMContracts

public protocol ToolBatchExecuting: Sendable {
    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion
    func cancel(batchID: String) async
    func finish(runID: String) async
}

public extension ToolBatchExecuting {
    func finish(runID _: String) async {}
}
