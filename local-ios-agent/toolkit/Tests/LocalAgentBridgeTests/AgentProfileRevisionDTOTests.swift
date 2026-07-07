import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Agent profile revision DTOs")
struct AgentProfileRevisionDTOTests {
    @Test
    func startExecutionRequestEncodesProfileRevisionId() throws {
        let request = StartExecutionRequestDTO(
            agentProfileId: "profile_1",
            profileRevisionId: 1,
            userIntent: "hello",
            conversationRunFrameRef: ConversationRunFrameRefDTO(
                frameId: "frame_1",
                sessionId: "session_1",
                branchHeadId: "user_1",
                userTurnId: "user_1"
            )
        )

        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["agent_profile_id"] as? String == "profile_1")
        #expect(object["profile_revision_id"] as? Int == 1)
        #expect(object["user_intent"] as? String == "hello")
    }

    @Test
    func agentProfileDTOCarriesLatestRevision() throws {
        let profile = AgentProfileDTO(
            profileId: "profile_1",
            profileRevisionId: 2,
            displayName: "Assistant"
        )

        let data = try JSONEncoder().encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["profile_id"] as? String == "profile_1")
        #expect(object["profile_revision_id"] as? Int == 2)
    }
}
