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

    @Test("shell consumes chat intents into route and composer draft")
    func shellConsumesChatIntent() {
        let shell = AppShellViewModel()

        shell.handleAppIntent(.startChat(prefilledText: "Inspect this"))

        guard case let .chat(sessionID) = shell.route else {
            Issue.record("start chat did not open chat")
            return
        }
        #expect(sessionID?.hasPrefix("conversation-") == true)
        #expect(shell.consumePendingChatDraft() == "Inspect this")
        #expect(shell.consumePendingChatDraft() == nil)
    }

    @Test("a nil chat route allocates a new stream instead of reusing current")
    func nilChatRouteCreatesNewConversation() {
        let shell = AppShellViewModel(route: .chat(sessionId: nil))

        let resolved = shell.resolveChatConversationID(
            currentConversationID: "conversation-current"
        )

        #expect(resolved != "conversation-current")
        #expect(shell.route == .chat(sessionId: resolved))
    }

    @Test("capture text selects the requested agent and starts a new stream")
    func captureTextSelectsTargetAgent() {
        let shell = AppShellViewModel(
            activeAgent: .init(
                profileId: "agent-a",
                profileRevisionId: 1,
                displayName: "Agent A"
            ),
            availableAgents: [
                .init(
                    profileId: "agent-a",
                    profileRevisionId: 1,
                    displayName: "Agent A"
                ),
                .init(
                    profileId: "agent-b",
                    profileRevisionId: 3,
                    displayName: "Agent B"
                ),
            ]
        )

        shell.handleAppIntent(.captureText(
            text: "Inspect this",
            targetAgentProfileId: "agent-b"
        ))

        #expect(shell.activeAgent?.profileId == "agent-b")
        #expect(shell.activeAgent?.profileRevisionId == 3)
        guard case let .chat(sessionID) = shell.route else {
            Issue.record("capture text did not open chat")
            return
        }
        #expect(sessionID?.hasPrefix("conversation-") == true)
        #expect(shell.consumePendingChatDraft() == "Inspect this")
    }

    @Test("shell routes continue-conversation intent to the requested stream")
    func shellConsumesContinueConversationIntent() {
        let shell = AppShellViewModel()

        shell.handleAppIntent(.continueConversation(conversationId: "session_7"))

        #expect(shell.route == .chat(sessionId: "session_7"))
    }
}
