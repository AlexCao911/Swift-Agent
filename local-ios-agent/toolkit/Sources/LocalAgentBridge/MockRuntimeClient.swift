import Foundation

public actor MockRuntimeClient: RuntimeClient, ProviderControllingRuntimeClient, RuntimeOptionsControllingRuntimeClient, ConversationRuntimeClient, ConversationBridgeClient, ExecutionBridgeClient {
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

    public struct ToolApprovalSubmission: Equatable, Sendable {
        public var id: String
        public var decision: ApprovalDecisionDTO

        public init(id: String, decision: ApprovalDecisionDTO) {
            self.id = id
            self.decision = decision
        }
    }

    private var storedSessionIds: [String]
    private var storedConversationSummaries: [ConversationSummaryDTO]
    private var storedActiveBranch: [RuntimeEventDTO]
    private var storedAgentProfiles: [AgentProfileDTO]
    private nonisolated let splitState: MockRuntimeSplitState
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
    public private(set) var preparedUserTurnRequests: [PrepareUserTurnRequestDTO] = []
    public private(set) var commitAssistantResultRequests: [CommitAssistantResultRequestDTO] = []
    public private(set) var startedExecutionRequests: [StartExecutionRequestDTO] = []
    public private(set) var approvedTools: [ToolApprovalSubmission] = []
    public private(set) var builtAgentTemplateIds: [String] = []
    public private(set) var builtAgentRequests: [BuildAgentRequestDTO] = []
    public private(set) var updatedRuntimeOptions: [RuntimeOptionsDTO] = []

    public init(
        sessionIds: [String] = [],
        conversationSummaries: [ConversationSummaryDTO] = [],
        activeBranch: [RuntimeEventDTO] = [],
        agentProfiles: [AgentProfileDTO] = [
            AgentProfileDTO(
                profileId: "profile_mock",
                profileRevisionId: 1,
                displayName: "Mock Agent"
            )
        ],
        executionEventsByRunId: [String: [RuntimeEventDTO]] = [:],
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
        self.storedConversationSummaries = conversationSummaries
        self.storedActiveBranch = activeBranch
        self.storedAgentProfiles = agentProfiles
        self.splitState = MockRuntimeSplitState(executionEventsByRunId: executionEventsByRunId)
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

    public func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        startedExecutionRequests.append(request)
        return RunHandleDTO(runId: turnResult.runId, replayFromSequence: 0)
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

    public func conversationSummaries() async throws -> [ConversationSummaryDTO] {
        storedConversationSummaries
    }

    public func listSessions() async throws -> [ConversationSummaryDTO] {
        storedConversationSummaries
    }

    public func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        preparedUserTurnRequests.append(request)
        let sessionId = request.sessionId ?? storedSessionIds.last ?? "session_mock"
        let branchHeadId = request.parentEventId ?? "entry_root"
        let userMessageId = "entry_user_\(preparedUserTurnRequests.count)"
        let frameRef = ConversationRunFrameRefDTO(
            frameId: "frame_\(preparedUserTurnRequests.count)",
            sessionId: sessionId,
            branchHeadId: branchHeadId,
            userTurnId: userMessageId
        )
        return PreparedUserTurnDTO(
            sessionId: sessionId,
            userMessageId: userMessageId,
            conversationRunFrameRef: frameRef,
            framePreview: ConversationRunFrameDTO(
                frameRef: frameRef,
                messages: [
                    ConversationFrameMessageDTO(
                        eventId: userMessageId,
                        role: "user",
                        content: request.text
                    )
                ],
                attachmentRefs: request.blobRefs
            )
        )
    }

    public func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        storedActiveBranch
    }

    public func forkSession(sessionId: String, leafId: String) async throws -> String {
        "session_forked"
    }

    public func archiveSession(sessionId: String) async throws {}

    public func renameSession(sessionId: String, title: String) async throws {}

    public func deleteSession(sessionId: String) async throws {}

    public func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        commitAssistantResultRequests.append(request)
        return ConversationCommitResultDTO(
            committedMessageId: "assistant.\(request.runId).\(request.finalMessageId)",
            alreadyCommitted: false
        )
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

    public func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        try await cancel(runId: runId)
    }

    public func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        promptDebugSnapshot
    }

    public func listAgentProfiles() async throws -> [AgentProfileDTO] {
        storedAgentProfiles
    }

    public func buildAgent(_ request: BuildAgentRequestDTO) async throws -> AgentProfileDTO {
        builtAgentRequests.append(request)
        builtAgentTemplateIds.append(request.templateId)
        return storedAgentProfiles.first ?? AgentProfileDTO(
            profileId: request.profileId ?? "profile_mock",
            profileRevisionId: 1,
            displayName: "Mock Agent"
        )
    }

    public nonisolated func observeEvents(
        runId: String,
        fromSequence: UInt64
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        splitState.observeEvents(runId: runId, fromSequence: fromSequence)
    }

    public func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        approvedTools.append(ToolApprovalSubmission(id: id, decision: decision))
    }

    public func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        updatedRuntimeOptions.append(options)
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

private final class MockRuntimeSplitState: @unchecked Sendable {
    private let lock = NSLock()
    private var executionEventsByRunId: [String: [RuntimeEventDTO]]

    init(executionEventsByRunId: [String: [RuntimeEventDTO]]) {
        self.executionEventsByRunId = executionEventsByRunId
    }

    func observeEvents(
        runId: String,
        fromSequence: UInt64
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        let events = self.events(runId: runId, fromSequence: fromSequence)
        return AsyncThrowingStream<RuntimeEventDTO, Error> { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private func events(runId: String, fromSequence: UInt64) -> [RuntimeEventDTO] {
        lock.lock()
        defer { lock.unlock() }
        return (executionEventsByRunId[runId] ?? [])
            .filter { $0.sequence > fromSequence }
    }
}
