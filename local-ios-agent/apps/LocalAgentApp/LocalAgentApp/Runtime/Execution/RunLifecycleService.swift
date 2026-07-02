import LocalAgentBridge

struct RunLifecycleService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        try await bridge.startRun(request)
    }

    func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await bridge.cancelRun(runId: runId)
    }
}

#if DEBUG
extension RunLifecycleService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
