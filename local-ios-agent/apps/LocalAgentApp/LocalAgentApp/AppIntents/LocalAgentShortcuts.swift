import AppIntents

struct OpenLocalAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Local Agent"
    static let description = IntentDescription("Open Local Agent to a chat destination.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination")
    var destination: LocalAgentIntentDestination

    init() {
        destination = .chat
    }

    init(destination: LocalAgentIntentDestination) {
        self.destination = destination
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppIntentRouter.shared.open(AppIntentRoute(destination: destination))
        }
        return .result()
    }
}

struct OpenAgentBuilderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Agent Builder"
    static let description = IntentDescription("Open Local Agent to the agent builder.")
    static let openAppWhenRun = true

    @Parameter(title: "Agent")
    var agent: AgentEntity?

    init() {
        agent = nil
    }

    init(agent: AgentEntity?) {
        self.agent = agent
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppIntentRouter.shared.open(
                AppIntentRoute.openBuilder(profileId: agent?.id)
            )
        }
        return .result()
    }
}

struct StartLocalAgentChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Chat"
    static let description = IntentDescription("Open Local Agent with an optional prompt ready to send.")
    static let openAppWhenRun = true

    @Parameter(
        title: "Prompt",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var prompt: String?

    init() {
        prompt = nil
    }

    init(prompt: String?) {
        self.prompt = prompt
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppIntentRouter.shared.open(
                AppIntentRoute.startChat(prefilledText: prompt)
            )
        }
        return .result()
    }
}

struct ContinueLocalAgentConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Conversation"
    static let description = IntentDescription("Open a Local Agent conversation.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    init() {
        conversation = ConversationEntity(id: "", title: "Choose Conversation")
    }

    init(conversation: ConversationEntity) {
        self.conversation = conversation
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppIntentRouter.shared.open(
                AppIntentRoute.continueConversation(conversationId: conversation.id)
            )
        }
        return .result()
    }
}

struct CaptureTextWithAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text"
    static let description = IntentDescription("Send selected text into Local Agent.")
    static let openAppWhenRun = true

    @Parameter(
        title: "Text",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var text: String

    @Parameter(title: "Agent")
    var agent: AgentEntity?

    init() {
        text = ""
        agent = nil
    }

    init(text: String, agent: AgentEntity?) {
        self.text = text
        self.agent = agent
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppIntentRouter.shared.open(
                AppIntentRoute.captureText(
                    text: text,
                    targetAgentProfileId: agent?.id
                )
            )
        }
        return .result()
    }
}

struct LocalAgentAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLocalAgentIntent(destination: .chat),
            phrases: [
                "Open \(.applicationName)",
                "Open chat in \(.applicationName)",
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.text.bubble.right"
        )

        AppShortcut(
            intent: OpenLocalAgentIntent(destination: .conversations),
            phrases: [
                "Show chats in \(.applicationName)",
                "Open conversations in \(.applicationName)",
            ],
            shortTitle: "Chats",
            systemImageName: "sidebar.left"
        )

        AppShortcut(
            intent: StartLocalAgentChatIntent(),
            phrases: [
                "Start chat with \(.applicationName)",
                "Draft with \(.applicationName)",
            ],
            shortTitle: "Start Chat",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: OpenAgentBuilderIntent(),
            phrases: [
                "Build an agent in \(.applicationName)",
                "Open agent builder in \(.applicationName)",
            ],
            shortTitle: "Agent Builder",
            systemImageName: "rectangle.3.group"
        )

        AppShortcut(
            intent: CaptureTextWithAgentIntent(),
            phrases: [
                "Capture text with \(.applicationName)",
                "Send text to \(.applicationName)",
            ],
            shortTitle: "Capture Text",
            systemImageName: "text.viewfinder"
        )

        AppShortcut(
            intent: OpenLocalAgentIntent(destination: .settings),
            phrases: [
                "Open settings in \(.applicationName)",
                "Show model settings in \(.applicationName)",
            ],
            shortTitle: "Settings",
            systemImageName: "slider.horizontal.3"
        )
    }
}
