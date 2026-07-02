import LocalAgentBridge

struct InferenceSettingsService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        try await bridge.updateRuntimeOptions(options)
    }
}

#if DEBUG
extension InferenceSettingsService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
