public protocol RuntimeClient: Sendable {
    func createSession() async throws -> String
    func sessionIds() async throws -> [String]
    func registerToolSchema(_ schema: ToolSchemaDTO) async throws
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws
    func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) async throws -> AgentTurnResultDTO
    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO]
    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO]
    func submitToolResult(
        runId: String,
        result: ToolResultDTO
    ) async throws -> AgentTurnResultDTO
    func submitApprovalResponse(
        _ response: ApprovalProtocolResponseDTO
    ) async throws -> AgentTurnResultDTO
    func cancel(runId: String) async throws -> RuntimeEventDTO
    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO?
}

public protocol ProviderControllingRuntimeClient: Sendable {
    func providerProfiles() async throws -> [ProviderProfileDTO]
    func activeProvider() async throws -> ProviderProfileDTO
    func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO
}
