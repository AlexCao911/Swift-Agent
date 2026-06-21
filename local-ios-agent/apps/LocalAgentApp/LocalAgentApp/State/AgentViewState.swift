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
    var sessionId: String?
    var parentId: String?
    var parts: [MessagePartViewState] {
        didSet {
            if !isUpdatingPartsFromSource {
                sourceText = parts.map(\.plainText).joined()
            }
        }
    }
    var attachments: [AttachmentViewState]
    var streaming: MessageStreamingState
    private var sourceText: String
    private var isUpdatingPartsFromSource: Bool

    init(
        id: String,
        sessionId: String? = nil,
        parentId: String? = nil,
        role: AgentMessageRole,
        parts: [MessagePartViewState],
        attachments: [AttachmentViewState] = [],
        streaming: MessageStreamingState = .idle
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.role = role
        self.parts = parts
        self.attachments = attachments
        self.streaming = streaming
        sourceText = parts.map(\.plainText).joined()
        isUpdatingPartsFromSource = false
    }

    init(id: String, role: AgentMessageRole, text: String, isStreaming: Bool) {
        self.id = id
        self.role = role
        sessionId = nil
        parentId = nil
        attachments = []
        streaming = isStreaming ? .streaming : .idle
        sourceText = text
        isUpdatingPartsFromSource = false
        parts = Self.parts(for: role, text: text, isStreaming: isStreaming)
    }

    var text: String {
        get {
            parts.map(\.plainText).joined()
        }
        set {
            sourceText = newValue
            updatePartsFromSource()
        }
        _modify {
            defer {
                updatePartsFromSource()
            }
            yield &sourceText
        }
    }

    var isStreaming: Bool {
        get {
            streaming.isStreaming
        }
        set {
            streaming = newValue ? .streaming : .idle
            updatePartsFromSource()
        }
    }

    private mutating func updatePartsFromSource() {
        isUpdatingPartsFromSource = true
        parts = Self.parts(for: role, text: sourceText, isStreaming: isStreaming)
        isUpdatingPartsFromSource = false
    }

    private static func parts(for role: AgentMessageRole, text: String, isStreaming: Bool) -> [MessagePartViewState] {
        switch role {
        case .assistant:
            var parser = ReasoningTagParser()
            parser.append(text)
            return parser.snapshot(isFinal: !isStreaming)
        case .tool:
            guard !text.isEmpty else {
                return []
            }
            return [.tool(ToolPartViewState(id: "tool_0", displayText: text))]
        case .user:
            guard !text.isEmpty else {
                return []
            }
            return [.text(TextPartViewState(id: "text_0", text: text))]
        }
    }
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
