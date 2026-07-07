import Testing
@testable import LocalAgentApp

@Suite("App intent routing")
@MainActor
struct AppIntentRoutingTests {
    @Test("agent.open_builder routes to Builder")
    func openBuilderRoutesToBuilder() {
        let route = AppIntentRoute.openBuilder(profileId: "profile_1")

        #expect(route.intentIdentifier == "agent.open_builder")
        #expect(route.destination == .openBuilder(profileId: "profile_1"))
        #expect(route.opensBuilder == true)
        #expect(route.opensChat == false)
    }

    @Test("agent.capture_text opens Chat when an agent is selected")
    func captureTextWithTargetAgentRoutesToChat() {
        let route = AppIntentRoute.captureText(
            text: "Summarize this page",
            targetAgentProfileId: "profile_1"
        )

        #expect(route.intentIdentifier == "agent.capture_text")
        #expect(route.destination == .captureText(
            text: "Summarize this page",
            targetAgentProfileId: "profile_1"
        ))
        #expect(route.opensChat == true)
        #expect(route.opensBuilder == false)
    }

    @Test("agent.capture_text opens Builder when no agent is selected")
    func captureTextWithoutTargetAgentRoutesToBuilder() {
        let route = AppIntentRoute.captureText(
            text: "Summarize this page",
            targetAgentProfileId: nil
        )

        #expect(route.destination == .captureText(
            text: "Summarize this page",
            targetAgentProfileId: nil
        ))
        #expect(route.opensChat == false)
        #expect(route.opensBuilder == true)
    }

    @Test("agent.continue_conversation routes to conversation")
    func continueConversationRoutesToConversation() {
        let route = AppIntentRoute.continueConversation(conversationId: "session_7")

        #expect(route.intentIdentifier == "agent.continue_conversation")
        #expect(route.destination == .openChat(conversationId: "session_7"))
        #expect(route.startsNewChat == false)
    }

    @Test("agent.continue_conversation without id opens conversation list")
    func continueConversationWithoutIdRoutesToConversationList() {
        let route = AppIntentRoute.continueConversation(conversationId: "")

        #expect(route.intentIdentifier == "agent.continue_conversation")
        #expect(route.destination == .openConversationList)
    }
}
