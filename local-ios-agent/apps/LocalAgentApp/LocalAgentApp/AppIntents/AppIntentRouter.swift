import AppIntents
import Foundation
import Observation

enum LocalAgentIntentDestination: String, AppEnum, CaseIterable, Sendable {
    case chat
    case conversations

    static var typeDisplayName: LocalizedStringResource { "Destination" }
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Destination")

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .chat: DisplayRepresentation(title: "Chat"),
            .conversations: DisplayRepresentation(title: "Conversations"),
        ]
    }
}

struct AppIntentRoute: Equatable, Identifiable, Sendable {
    let id = UUID()
    var destination: LocalAgentIntentDestination
    var startsNewChat = false
    var prefilledText: String?
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
