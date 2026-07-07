enum AppRoute: Equatable, Sendable {
    case chat(sessionId: String?)
    case agents(profileId: String?)
    case builder(profileId: String?, revisionId: UInt64?)
    case tools(focusedToolName: String?)
    case models
    case settings
    case debug(runId: String?)

    var family: AppRouteFamily {
        switch self {
        case .chat:
            .chat
        case .agents, .builder:
            .agents
        case .tools:
            .tools
        case .models:
            .models
        case .settings:
            .settings
        case .debug:
            .debug
        }
    }
}

enum AppRouteFamily: String, Codable, Equatable, Sendable {
    case chat
    case agents
    case tools
    case models
    case settings
    case debug
}

struct ActiveAgentRevisionSelection: Equatable, Sendable {
    var profileId: String
    var profileRevisionId: UInt64
    var displayName: String
}

enum ModelRouteKind: Equatable, Sendable {
    case localCpp(engineId: String)
    case cloud(providerId: String)
    case unset
}

enum ModelReadiness: Equatable, Sendable {
    case ready
    case missingConfiguration(reason: String)
    case unavailable(reason: String)
}

struct ActiveModelSummary: Equatable, Sendable {
    var providerId: String
    var modelId: String
    var displayName: String
    var route: ModelRouteKind
    var readiness: ModelReadiness
}

struct GlobalReadinessBanner: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case missingAgent
        case missingModel
        case permission
        case runtime
    }

    var id: String
    var kind: Kind
    var title: String
    var message: String
    var route: AppRoute?
}

struct AppShellPersistedState: Codable, Equatable, Sendable {
    var activeProfileId: String?
    var activeProfileRevisionId: UInt64?
    var lastRouteFamily: AppRouteFamily
    var activeModelId: String?
}
