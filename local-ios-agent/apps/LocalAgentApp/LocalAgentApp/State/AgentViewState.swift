import LocalAgentBridge

enum AppRuntimePhase: Equatable, Sendable {
    case booting
    case ready
    case running(runId: String)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

enum AgentMessageRole: Equatable, Sendable {
    case user
    case assistant
    case tool
}

struct AgentMessageViewState: Equatable, Identifiable, Sendable {
    let id: String
    let role: AgentMessageRole
    var text: String
    var isStreaming: Bool
}

struct ProviderSelectionViewState: Equatable, Sendable {
    var profiles: [ProviderProfileDTO]
    var active: ProviderProfileDTO?
    var errorMessage: String?

    init(
        profiles: [ProviderProfileDTO] = [],
        active: ProviderProfileDTO? = nil,
        errorMessage: String? = nil
    ) {
        self.profiles = profiles
        self.active = active
        self.errorMessage = errorMessage
    }
}

struct AgentViewState: Equatable, Sendable {
    var phase: AppRuntimePhase
    var messages: [AgentMessageViewState]
    var draft: String
    var currentSessionId: String?
    var errorMessage: String?
    var provider: ProviderSelectionViewState

    init(
        phase: AppRuntimePhase = .booting,
        messages: [AgentMessageViewState] = [],
        draft: String = "",
        currentSessionId: String? = nil,
        errorMessage: String? = nil,
        provider: ProviderSelectionViewState = ProviderSelectionViewState()
    ) {
        self.phase = phase
        self.messages = messages
        self.draft = draft
        self.currentSessionId = currentSessionId
        self.errorMessage = errorMessage
        self.provider = provider
    }
}
