import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Chat interaction coordinator")
@MainActor
struct ChatInteractionCoordinatorTests {
    @Test("send message prepares frame ref starts run observes and commits")
    func sendMessagePreparesFrameRefStartsRunObservesAndCommits() async throws {
        let frameRef = conversationRunFrameRef()
        let conversation = FakeConversationDomain(preparedTurn: PreparedUserTurnDTO(
            sessionId: "session_1",
            userMessageId: "user_turn_1",
            conversationRunFrameRef: frameRef
        ))
        let execution = FakeExecutionDomain(
            handle: RunHandleDTO(runId: "run_1", replayFromSequence: 0),
            events: [
                runtimeEvent(
                    id: "event_1",
                    runId: "run_1",
                    sequence: 1,
                    kind: .unknown(raw: "execution.event"),
                    payload: "run.started"
                ),
                runtimeEvent(
                    id: "assistant_1",
                    runId: "run_1",
                    sequence: 2,
                    kind: .assistantMessageCompleted,
                    payload: #"{"message_id":"assistant_1","text":"hello"}"#
                ),
            ]
        )
        let coordinator = ChatInteractionCoordinator(
            conversation: conversation,
            execution: execution
        )
        var observed: [RuntimeEventDTO] = []

        _ = try await coordinator.sendMessage(
            text: "hello",
            sessionId: "session_1",
            parentEventId: nil,
            agentProfileId: "profile_1",
            agentProfileRevisionId: 1,
            options: ExecutionOptionsDTO(),
            onEvent: { observed.append($0) }
        )

        #expect(execution.startedRequests.first?.conversationRunFrameRef == frameRef)
        #expect(execution.startedRequests.first?.profileRevisionId == 1)
        #expect(await conversation.committedRequests.first?.runId == "run_1")
        #expect(await conversation.committedRequests.first?.finalMessageId == "assistant_1")
        #expect(observed.map(\.id) == ["user_turn_1", "event_1", "assistant_1"])
        #expect(observed.first?.kind == .userMessage)
        #expect(observed.first?.payload == "hello")
        #expect(observed.first?.sessionId == "session_1")
    }

    @Test("completed run commit can be retried after send commit failure")
    func completedRunCommitCanBeRetriedAfterSendCommitFailure() async throws {
        let frameRef = conversationRunFrameRef()
        let conversation = FakeConversationDomain(
            preparedTurn: PreparedUserTurnDTO(
                sessionId: "session_1",
                userMessageId: "user_turn_1",
                conversationRunFrameRef: frameRef
            ),
            commitResults: [
                .failure(CommitFailure.transient),
                .success(ConversationCommitResultDTO(
                    committedMessageId: "assistant_1",
                    alreadyCommitted: true
                )),
            ]
        )
        let execution = FakeExecutionDomain(events: [
            runtimeEvent(
                id: "assistant_1",
                runId: "run_1",
                sequence: 2,
                kind: .assistantMessageCompleted,
                payload: #"{"message_id":"assistant_1","text":"hello"}"#
            ),
        ])
        let coordinator = ChatInteractionCoordinator(
            conversation: conversation,
            execution: execution
        )

        do {
            _ = try await coordinator.sendMessage(
                text: "hello",
                sessionId: "session_1",
                parentEventId: nil,
                agentProfileId: "profile_1",
                agentProfileRevisionId: 1,
                options: ExecutionOptionsDTO()
            )
            Issue.record("Expected first commit to fail")
        } catch CommitFailure.transient {}

        try await coordinator.recoverCompletedRunCommit(
            runId: "run_1",
            finalMessageId: "assistant_1",
            frameRef: frameRef
        )

        #expect(await conversation.committedRequests.count == 2)
    }

    @Test("waiting tool run is executed submitted observed and committed")
    func waitingToolRunIsExecutedSubmittedObservedAndCommitted() async throws {
        let frameRef = conversationRunFrameRef()
        let conversation = FakeConversationDomain(preparedTurn: PreparedUserTurnDTO(
            sessionId: "session_1",
            userMessageId: "user_turn_1",
            conversationRunFrameRef: frameRef
        ))
        let execution = FakeExecutionDomain(
            eventBatches: [
                [
                    runtimeEvent(
                        id: "tool_call_entry",
                        runId: "run_1",
                        sequence: 1,
                        kind: .toolCallRequested,
                        payload: #"{"tool_call_id":"call_1","tool_name":"debug.echo"}"#
                    ),
                    runtimeEvent(
                        id: "waiting",
                        runId: "run_1",
                        sequence: 2,
                        kind: .runWaitingTool,
                        payload: "run.waiting_tool"
                    ),
                ],
                [
                    runtimeEvent(
                        id: "tool_result_1",
                        runId: "run_1",
                        sequence: 3,
                        kind: .toolResultMessage,
                        payload: #"{"display_text":"Echo: hello"}"#
                    ),
                    runtimeEvent(
                        id: "assistant_1",
                        runId: "run_1",
                        sequence: 4,
                        kind: .assistantMessageCompleted,
                        payload: #"{"message_id":"assistant_1","text":"done"}"#
                    ),
                ],
            ],
            pendingToolRequests: [
                ToolExecutionRequestDTO(
                    runId: "run_1",
                    sessionId: "session_1",
                    toolCallEntryId: "tool_call_entry",
                    toolCallId: "call_1",
                    toolName: "debug.echo",
                    argumentsJson: #"{"text":"hello"}"#
                ),
            ]
        )
        let coordinator = ChatInteractionCoordinator(
            conversation: conversation,
            execution: execution,
            toolDriver: MinimalHostToolDriver()
        )
        var observed: [RuntimeEventDTO] = []

        _ = try await coordinator.sendMessage(
            text: "use tool debug.echo",
            sessionId: "session_1",
            parentEventId: nil,
            agentProfileId: "profile_1",
            agentProfileRevisionId: 1,
            options: ExecutionOptionsDTO(),
            onEvent: { observed.append($0) }
        )

        #expect(execution.observeCalls.map(\.fromSequence) == [0, 2])
        #expect(execution.submittedToolResults.map(\.runId) == ["run_1"])
        #expect(execution.submittedToolResults.first?.result.modelText == "debug.echo: hello")
        #expect(await conversation.committedRequests.first?.finalMessageId == "assistant_1")
        #expect(observed.map(\.id) == [
            "user_turn_1",
            "tool_call_entry",
            "waiting",
            "tool_result_1",
            "assistant_1",
        ])
    }

    @Test("approval and cancellation pass through execution domain")
    func approvalAndCancellationPassThroughExecutionDomain() async throws {
        let execution = FakeExecutionDomain()
        let coordinator = ChatInteractionCoordinator(
            conversation: FakeConversationDomain(),
            execution: execution
        )

        try await coordinator.approveTool(
            id: "approval_1",
            decision: ApprovalDecisionDTO(approved: true)
        )
        try await coordinator.cancelRun(runId: "run_1")

        #expect(execution.approvedTools.map { $0.id } == ["approval_1"])
        #expect(execution.cancelledRunIds == ["run_1"])
    }
}

private actor FakeConversationDomain: ConversationDomain {
    var committedRequests: [CommitAssistantResultRequestDTO] = []
    private let preparedTurn: PreparedUserTurnDTO
    private var commitResults: [Result<ConversationCommitResultDTO, Error>]

    init(
        preparedTurn: PreparedUserTurnDTO = PreparedUserTurnDTO(
            sessionId: "session_1",
            userMessageId: "user_turn_1",
            conversationRunFrameRef: conversationRunFrameRef()
        ),
        commitResults: [Result<ConversationCommitResultDTO, Error>] = []
    ) {
        self.preparedTurn = preparedTurn
        self.commitResults = commitResults
    }

    func listSessions() async throws -> [ConversationSummaryDTO] {
        []
    }

    func prepareUserTurn(_ request: PrepareUserTurnRequestDTO) async throws -> PreparedUserTurnDTO {
        preparedTurn
    }

    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        []
    }

    func forkSession(sessionId: String, leafId: String) async throws -> String {
        sessionId
    }

    func archiveSession(sessionId: String) async throws {}

    func renameSession(sessionId: String, title: String) async throws {}

    func deleteSession(sessionId: String) async throws {}

    func commitAssistantResult(_ request: CommitAssistantResultRequestDTO) async throws -> ConversationCommitResultDTO {
        committedRequests.append(request)
        if !commitResults.isEmpty {
            return try commitResults.removeFirst().get()
        }
        return ConversationCommitResultDTO(
            committedMessageId: request.finalMessageId,
            alreadyCommitted: false
        )
    }
}

private final class FakeExecutionDomain: @unchecked Sendable, ExecutionDomain {
    struct ObserveCall: Equatable {
        var runId: String
        var fromSequence: UInt64
    }

    var startedRequests: [StartExecutionRequestDTO] = []
    var observeCalls: [ObserveCall] = []
    var approvedTools: [(id: String, decision: ApprovalDecisionDTO)] = []
    var submittedToolResults: [(runId: String, result: ToolResultDTO)] = []
    var cancelledRunIds: [String] = []
    var pendingToolRequests: [ToolExecutionRequestDTO]
    private let handle: RunHandleDTO
    private var eventBatches: [[RuntimeEventDTO]]

    init(
        handle: RunHandleDTO = RunHandleDTO(runId: "run_1", replayFromSequence: 0),
        events: [RuntimeEventDTO] = [],
        eventBatches: [[RuntimeEventDTO]]? = nil,
        pendingToolRequests: [ToolExecutionRequestDTO] = []
    ) {
        self.handle = handle
        self.eventBatches = eventBatches ?? [events]
        self.pendingToolRequests = pendingToolRequests
    }

    func listAgentProfiles() async throws -> [AgentProfileDTO] {
        []
    }

    func buildAgent(templateId: String) async throws -> AgentProfileDTO {
        AgentProfileDTO(profileId: templateId, profileRevisionId: 1, displayName: templateId)
    }

    func startRun(_ request: StartExecutionRequestDTO) async throws -> RunHandleDTO {
        startedRequests.append(request)
        return handle
    }

    func observeEvents(runId: String, fromSequence: UInt64) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        observeCalls.append(ObserveCall(runId: runId, fromSequence: fromSequence))
        let events = eventBatches.isEmpty ? [] : eventBatches.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events where event.sequence > fromSequence {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        pendingToolRequests
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        approvedTools.append((id: id, decision: decision))
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        submittedToolResults.append((runId: runId, result: result))
        pendingToolRequests.removeAll { $0.runId == runId }
        return AgentTurnResultDTO(
            runId: runId,
            state: .completed,
            events: [],
            pendingToolCallId: nil
        )
    }

    func cancelRun(runId: String) async throws -> RuntimeEventDTO {
        cancelledRunIds.append(runId)
        return runtimeEvent(
            id: "cancelled",
            runId: runId,
            sequence: 3,
            kind: .runCancelled,
            payload: "cancelled"
        )
    }

    func loadDebugArchive(_ runId: String) async throws -> RunDebugUIModel {
        RunDebugUIModel(runId: runId, state: .completed, events: [], checkpoints: [])
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {}
}

private enum CommitFailure: Error {
    case transient
}

private func conversationRunFrameRef() -> ConversationRunFrameRefDTO {
    ConversationRunFrameRefDTO(
        frameId: "frame_1",
        sessionId: "session_1",
        branchHeadId: "branch_head_1",
        userTurnId: "user_turn_1"
    )
}

private func runtimeEvent(
    id: String,
    runId: String,
    sequence: UInt64,
    kind: RuntimeEventKindDTO,
    payload: String
) -> RuntimeEventDTO {
    RuntimeEventDTO(
        id: id,
        sessionId: "session_1",
        parentId: nil,
        runId: runId,
        sequence: sequence,
        depth: 0,
        kind: kind,
        payload: payload,
        blobRefs: []
    )
}
