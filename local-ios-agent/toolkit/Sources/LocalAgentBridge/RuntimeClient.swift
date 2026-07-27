/// Provider-neutral operations still used by the split conversation/execution bridges.
public protocol RuntimeClient: Sendable {
    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel
    func registerToolSchema(_ schema: ToolSchemaDTO) async throws
    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO]
    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO]
}

public extension RuntimeClient {
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

public protocol ConversationRuntimeClient: Sendable {
    func conversationSummaries() async throws -> [ConversationSummaryDTO]
    func forkSession(sessionId: String, leafId: String) async throws -> String
    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO]
    func archiveSession(sessionId: String) async throws
    func renameSession(sessionId: String, title: String) async throws
    func deleteSession(sessionId: String) async throws
}
