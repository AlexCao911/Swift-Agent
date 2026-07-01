public protocol RuntimeClient: Sendable {
    func startRun(_ request: StartRunRequestDTO) async throws -> RunHandleDTO
    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel
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

public extension RuntimeClient {
    func startRun(_ request: StartRunRequestDTO) async throws -> RunHandleDTO {
        throw RuntimeBridgeError(
            kind: "agent_os_start_run_unavailable",
            message: "Agent OS startRun application service is not linked by this runtime client"
        )
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        throw RuntimeBridgeError(
            kind: "agent_os_debug_archive_unavailable",
            message: "Agent OS debug archive loading is not linked by this runtime client"
        )
    }
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

public struct RuntimeOptionsDTO: Codable, Equatable, Sendable {
    public var systemPrompt: String
    public var runtimePolicy: String
    public var temperature: Double?
    public var topP: Double?

    public init(
        systemPrompt: String,
        runtimePolicy: String,
        temperature: Double?,
        topP: Double?
    ) {
        self.systemPrompt = systemPrompt
        self.runtimePolicy = runtimePolicy
        self.temperature = temperature
        self.topP = topP
    }

    private enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case runtimePolicy = "runtime_policy"
        case temperature
        case topP = "top_p"
    }
}

public protocol RuntimeOptionsControllingRuntimeClient: Sendable {
    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws
}

public protocol ConversationRuntimeClient: Sendable {
    func conversationSummaries() async throws -> [ConversationSummaryDTO]
    func forkSession(sessionId: String, leafId: String) async throws -> String
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func archiveSession(sessionId: String) async throws
    func renameSession(sessionId: String, title: String) async throws
    func deleteSession(sessionId: String) async throws
}
