import LocalAgentBridge

struct ToolApprovalService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        try await bridge.approveTool(id: id, decision: decision)
    }
}

#if DEBUG
extension ToolApprovalService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
