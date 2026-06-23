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
            AppIntentRouter.shared.open(AppIntentRoute(
                destination: .chat,
                startsNewChat: true,
                prefilledText: prompt
            ))
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
    }
}
