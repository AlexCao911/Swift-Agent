import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Conversation domain")
struct ConversationDomainTests {
    @Test("adapter delegates conversation frame preparation and final commit")
    func adapterDelegatesPrepareAndCommit() async throws {
        let frameRef = ConversationRunFrameRefDTO(
            frameId: "frame_1",
            sessionId: "session_1",
            branchHeadId: "entry_parent",
            userTurnId: "entry_user"
        )
        let bridge = MockRuntimeClient(
            sessionIds: ["session_1"],
            conversationSummaries: [
                ConversationSummaryDTO(
                    sessionId: "session_1",
                    title: "Planning",
                    activeLeafId: "entry_parent",
                    lastEventId: "entry_parent",
                    lastUpdatedSequence: 3
                ),
            ]
        )
        let domain = ConversationDomainAdapter(bridge: bridge)

        let sessions = try await domain.listSessions()
        let prepared = try await domain.prepareUserTurn(PrepareUserTurnRequestDTO(
            sessionId: "session_1",
            parentEventId: "entry_parent",
            text: "continue"
        ))
        let commit = try await domain.commitAssistantResult(CommitAssistantResultRequestDTO(
            runId: "run_1",
            finalMessageId: "final_1",
            conversationRunFrameRef: frameRef
        ))

        #expect(sessions.map(\.sessionId) == ["session_1"])
        #expect(prepared.conversationRunFrameRef.sessionId == "session_1")
        #expect(commit.committedMessageId == "assistant.run_1.final_1")
        #expect(await bridge.preparedUserTurnRequests.count == 1)
        #expect(await bridge.commitAssistantResultRequests.count == 1)
    }
}
