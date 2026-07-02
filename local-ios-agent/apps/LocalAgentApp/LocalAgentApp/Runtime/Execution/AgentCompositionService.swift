import LocalAgentBridge

struct AgentCompositionService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        try await bridge.buildAgent(templateId: templateId)
    }
}

#if DEBUG
extension AgentCompositionService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
