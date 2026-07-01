public actor MockRuntimeClient: RuntimeClient, ProviderControllingRuntimeClient {
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
    private var storedProviderProfiles: [ProviderProfileDTO]
    private var storedActiveProvider: ProviderProfileDTO
    private var toolRequests: [ToolExecutionRequestDTO]
    private var approvalRequests: [ApprovalProtocolRequestDTO]
    private var debugArchive: RunDebugUIModel

    public private(set) var registeredToolSchemas: [ToolSchemaDTO] = []
    public private(set) var permissionStates: [PermissionStateSubmission] = []
    public private(set) var startedRunRequests: [StartRunRequestDTO] = []
    public private(set) var sentMessages: [SentMessage] = []
    public private(set) var submittedToolResults: [ToolResultSubmission] = []
    public private(set) var submittedApprovalResponses: [ApprovalProtocolResponseDTO] = []
    public private(set) var cancelledRunIds: [String] = []
    public private(set) var selectedProviders: [(sessionId: String, providerId: String)] = []

    public init(
        sessionIds: [String] = [],
        turnResult: AgentTurnResultDTO = AgentTurnResultDTO(
            runId: "run_mock",
            state: .completed,
            events: [],
            pendingToolCallId: nil
        ),
        promptDebugSnapshot: PromptDebugSnapshotDTO? = nil,
        providerProfiles: [ProviderProfileDTO] = [
            ProviderProfileDTO(
                id: "mock",
                displayName: "Mock Provider",
                kind: .mock,
                maxContextTokens: 100
            )
        ],
        activeProvider: ProviderProfileDTO = ProviderProfileDTO(
            id: "mock",
            displayName: "Mock Provider",
            kind: .mock,
            maxContextTokens: 100
        ),
        toolRequests: [ToolExecutionRequestDTO] = [],
        approvalRequests: [ApprovalProtocolRequestDTO] = [],
        debugArchive: RunDebugUIModel = RunDebugUIModel(
            runId: "run_mock",
            state: .completed,
            events: [],
            checkpoints: []
        )
    ) {
        self.storedSessionIds = sessionIds
        self.turnResult = turnResult
        self.promptDebugSnapshot = promptDebugSnapshot
        self.storedProviderProfiles = providerProfiles
        self.storedActiveProvider = activeProvider
        self.toolRequests = toolRequests
        self.approvalRequests = approvalRequests
        self.debugArchive = debugArchive
    }

    public func startRun(_ request: StartRunRequestDTO) async throws -> RunHandleDTO {
        startedRunRequests.append(request)
        return RunHandleDTO(runId: turnResult.runId)
    }

    public func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        RunDebugUIModel(
            runId: runId,
            state: debugArchive.state,
            events: debugArchive.events,
            checkpoints: debugArchive.checkpoints
        )
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

    public func providerProfiles() async throws -> [ProviderProfileDTO] {
        storedProviderProfiles
    }

    public func activeProvider() async throws -> ProviderProfileDTO {
        storedActiveProvider
    }

    public func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO {
        selectedProviders.append((sessionId: sessionId, providerId: providerId))
        if let profile = storedProviderProfiles.first(where: { $0.id == providerId }) {
            storedActiveProvider = profile
        }
        return RuntimeEventDTO(
            id: "entry_mock_provider_changed",
            sessionId: sessionId,
            parentId: nil,
            runId: nil,
            sequence: 0,
            depth: 0,
            kind: .providerChanged,
            payload: #"{"provider_id":"\#(providerId)"}"#,
            blobRefs: []
        )
    }
}
