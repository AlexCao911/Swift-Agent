import LocalAgentBridge

struct AgentProfileService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func listAgentProfiles() async throws -> [AgentProfileDTO] {
        try await bridge.listAgentProfiles()
    }
}

#if DEBUG
extension AgentProfileService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
