import LocalAgentLLMContracts

public protocol ModelGenerationExecuting: Sendable {
    func generate(
        _ request: HostModelRequest,
        emit: @escaping @Sendable (HostModelEvent) async throws -> Void
    ) async throws

    func cancel(runID: String) async
}
