import LocalAgentBridge

struct RunDebugService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        try await bridge.loadDebugArchive(runId)
    }
}

#if DEBUG
extension RunDebugService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
