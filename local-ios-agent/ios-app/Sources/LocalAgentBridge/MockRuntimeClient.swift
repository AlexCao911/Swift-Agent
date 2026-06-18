public actor MockRuntimeClient: RuntimeClient {
    public struct SentMessage: Equatable, Sendable {
        public var sessionId: String
        public var parentEventId: String?
        public var text: String

        public init(sessionId: String, parentEventId: String?, text: String) {
            self.sessionId = sessionId
            self.parentEventId = parentEventId
            self.text = text
        }
    }

    public struct ToolResultSubmission: Equatable, Sendable {
        public var runId: String
        public var result: ToolResultDTO

        public init(runId: String, result: ToolResultDTO) {
            self.runId = runId
            self.result = result
        }
    }

    public struct PermissionStateSubmission: Equatable, Sendable {
        public var scope: String
        public var state: PermissionStateDTO

        public init(scope: String, state: PermissionStateDTO) {
            self.scope = scope
            self.state = state
        }
    }

    private var storedSessionIds: [String]
    private var turnResult: AgentTurnResultDTO
    private var promptDebugSnapshot: PromptDebugSnapshotDTO?
    private var toolRequests: [ToolExecutionRequestDTO]
    private var approvalRequests: [ApprovalProtocolRequestDTO]

    public private(set) var registeredToolSchemas: [ToolSchemaDTO] = []
    public private(set) var permissionStates: [PermissionStateSubmission] = []
    public private(set) var sentMessages: [SentMessage] = []
    public private(set) var submittedToolResults: [ToolResultSubmission] = []
    public private(set) var submittedApprovalResponses: [ApprovalProtocolResponseDTO] = []
    public private(set) var cancelledRunIds: [String] = []

    public init(
        sessionIds: [String] = [],
        turnResult: AgentTurnResultDTO = AgentTurnResultDTO(
            runId: "run_mock",
            state: .completed,
            events: [],
            pendingToolCallId: nil
        ),
        promptDebugSnapshot: PromptDebugSnapshotDTO? = nil,
        toolRequests: [ToolExecutionRequestDTO] = [],
        approvalRequests: [ApprovalProtocolRequestDTO] = []
    ) {
        self.storedSessionIds = sessionIds
        self.turnResult = turnResult
        self.promptDebugSnapshot = promptDebugSnapshot
        self.toolRequests = toolRequests
        self.approvalRequests = approvalRequests
    }

    public func createSession() async throws -> String {
        let sessionId = "session_\(storedSessionIds.count + 1)"
        storedSessionIds.append(sessionId)
        return sessionId
    }

    public func sessionIds() async throws -> [String] {
        storedSessionIds
    }

    public func registerToolSchema(_ schema: ToolSchemaDTO) async throws {
        registeredToolSchemas.append(schema)
    }

    public func setPermissionState(scope: String, state: PermissionStateDTO) async throws {
        permissionStates.append(PermissionStateSubmission(scope: scope, state: state))
    }

    public func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) async throws -> AgentTurnResultDTO {
        sentMessages.append(SentMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text
        ))
        return turnResult
    }

    public func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        toolRequests
    }

    public func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        approvalRequests
    }

    public func submitToolResult(
        runId: String,
        result: ToolResultDTO
    ) async throws -> AgentTurnResultDTO {
        submittedToolResults.append(ToolResultSubmission(runId: runId, result: result))
        return turnResult
    }

    public func submitApprovalResponse(
        _ response: ApprovalProtocolResponseDTO
    ) async throws -> AgentTurnResultDTO {
        submittedApprovalResponses.append(response)
        return turnResult
    }

    public func cancel(runId: String) async throws -> RuntimeEventDTO {
        cancelledRunIds.append(runId)
        return RuntimeEventDTO(
            id: "entry_mock_cancelled",
            sessionId: storedSessionIds.last ?? "session_mock",
            parentId: nil,
            runId: runId,
            sequence: 0,
            depth: 0,
            kind: .runCancelled,
            payload: "cancelled",
            blobRefs: []
        )
    }

    public func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        promptDebugSnapshot
    }
}
