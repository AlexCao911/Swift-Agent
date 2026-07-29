import LocalAgentLLMContracts

public protocol ToolBatchExecuting: Sendable {
    func execute(_ batch: HostToolBatch) async -> HostToolBatchCompletion
    func cancel(batchID: String) async
}
