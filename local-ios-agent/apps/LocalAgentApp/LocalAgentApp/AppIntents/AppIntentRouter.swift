import AppIntents
import Foundation
import Observation

enum LocalAgentIntentDestination: String, AppEnum, CaseIterable, Sendable {
    case chat
    case conversations
    case builder
    case prompts
    case settings

    static var typeDisplayName: LocalizedStringResource { "Destination" }
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Destination")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .chat: DisplayRepresentation(title: "Chat"),
            .conversations: DisplayRepresentation(title: "Conversations"),
            .builder: DisplayRepresentation(title: "Agent Builder"),
            .prompts: DisplayRepresentation(title: "Prompts"),
            .settings: DisplayRepresentation(title: "Settings"),
        ]
    }
}

enum AppIntentDestination: Equatable, Sendable {
    case openChat(conversationId: String?)
    case openBuilder(profileId: String?)
    case captureText(text: String, targetAgentProfileId: String?)
    case openConversationList
    case openPromptLibrary
    case openSettings
}

struct AppIntentRoute: Equatable, Identifiable, Sendable {
    let id = UUID()
    var intentIdentifier: String
    var destination: AppIntentDestination
    var startsNewChat = false
    var prefilledText: String?

    init(
        intentIdentifier: String,
        destination: AppIntentDestination,
        startsNewChat: Bool = false,
        prefilledText: String? = nil
    ) {
        self.intentIdentifier = intentIdentifier
        self.destination = destination
        self.startsNewChat = startsNewChat
        self.prefilledText = prefilledText
    }

    init(
        destination: LocalAgentIntentDestination,
        startsNewChat: Bool = false,
        prefilledText: String? = nil
    ) {
        self.init(
            intentIdentifier: "agent.open",
            destination: destination.appIntentDestination,
            startsNewChat: startsNewChat,
            prefilledText: prefilledText
        )
    }

    static func openBuilder(profileId: String?) -> AppIntentRoute {
        AppIntentRoute(
            intentIdentifier: "agent.open_builder",
            destination: .openBuilder(profileId: profileId)
        )
    }

    static func startChat(prefilledText: String?) -> AppIntentRoute {
        AppIntentRoute(
            intentIdentifier: "agent.start_chat",
            destination: .openChat(conversationId: nil),
            startsNewChat: true,
            prefilledText: prefilledText
        )
    }

    static func continueConversation(conversationId: String) -> AppIntentRoute {
        guard !conversationId.isEmpty else {
            return AppIntentRoute(
                intentIdentifier: "agent.continue_conversation",
                destination: .openConversationList
            )
        }
        AppIntentRoute(
            intentIdentifier: "agent.continue_conversation",
            destination: .openChat(conversationId: conversationId)
        )
    }

    static func captureText(text: String, targetAgentProfileId: String?) -> AppIntentRoute {
        AppIntentRoute(
            intentIdentifier: "agent.capture_text",
            destination: .captureText(
                text: text,
                targetAgentProfileId: targetAgentProfileId
            ),
            prefilledText: text
        )
    }

    var opensChat: Bool {
        switch destination {
        case .openChat:
            true
        case let .captureText(_, targetAgentProfileId):
            targetAgentProfileId != nil
        case .openBuilder, .openConversationList, .openPromptLibrary, .openSettings:
            false
        }
    }

    var opensBuilder: Bool {
        switch destination {
        case .openBuilder:
            true
        case let .captureText(_, targetAgentProfileId):
            targetAgentProfileId == nil
        case .openChat, .openConversationList, .openPromptLibrary, .openSettings:
            false
        }
    }
}

private extension LocalAgentIntentDestination {
    var appIntentDestination: AppIntentDestination {
        switch self {
        case .chat:
            .openChat(conversationId: nil)
        case .conversations:
            .openConversationList
        case .builder:
            .openBuilder(profileId: nil)
        case .prompts:
            .openPromptLibrary
        case .settings:
            .openSettings
        }
    }
}

@MainActor
@Observable
final class AppIntentRouter {
    static let shared = AppIntentRouter()

    private(set) var pendingRoute: AppIntentRoute?

    func open(_ route: AppIntentRoute) {
        pendingRoute = route
    }

    func consumePendingRoute() -> AppIntentRoute? {
        defer {
            pendingRoute = nil
        }
        return pendingRoute
    }
}
