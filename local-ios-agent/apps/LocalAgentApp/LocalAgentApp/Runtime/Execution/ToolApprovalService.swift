import LocalAgentBridge

struct ToolApprovalService: Sendable {
    private let bridge: any ExecutionBridgeClient

    init(bridge: any ExecutionBridgeClient) {
        self.bridge = bridge
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        try await bridge.approveTool(id: id, decision: decision)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        try await bridge.pendingToolRequests()
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        try await bridge.submitToolResult(runId: runId, result: result)
    }
}

#if DEBUG
extension ToolApprovalService {
    static var preview: Self {
        Self(bridge: MockRuntimeClient())
    }
}
#endif
