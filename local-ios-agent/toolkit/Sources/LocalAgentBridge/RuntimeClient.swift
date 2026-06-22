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

public struct AgentTurnStreamDTO: Sendable {
    public let events: AsyncThrowingStream<RuntimeEventDTO, Error>
    public let result: Task<AgentTurnResultDTO, Error>

    public init(
        events: AsyncThrowingStream<RuntimeEventDTO, Error>,
        result: Task<AgentTurnResultDTO, Error>
    ) {
        self.events = events
        self.result = result
    }
}

public protocol StreamingRuntimeClient: RuntimeClient {
    func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO

    func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO
}

public protocol BlobReferencingRuntimeClient: RuntimeClient {
    func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String,
        blobRefs: [String]
    ) async throws -> AgentTurnResultDTO
}

public protocol StreamingBlobReferencingRuntimeClient: StreamingRuntimeClient, BlobReferencingRuntimeClient {
    func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String,
        blobRefs: [String]
    ) -> AgentTurnStreamDTO
}

public protocol ProviderControllingRuntimeClient: Sendable {
    func providerProfiles() async throws -> [ProviderProfileDTO]
    func activeProvider() async throws -> ProviderProfileDTO
    func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO
}

public protocol ConversationRuntimeClient: Sendable {
    func conversationSummaries() async throws -> [ConversationSummaryDTO]
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func archiveSession(sessionId: String) async throws
    func deleteSession(sessionId: String) async throws
}
