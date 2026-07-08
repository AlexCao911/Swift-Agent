import Foundation
import LocalAgentBridge

enum AgentPromptDefaults {
    static let systemPrompt = "You are Local Agent."
    static let runtimePolicy = "Use registered tools when helpful. Ask before risky work."
}

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

enum RunTerminalReason: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
    case reachedLimit
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
    var branchLeafId: String?
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
        branchLeafId: String? = nil,
        role: AgentMessageRole,
        parts: [MessagePartViewState],
        attachments: [AttachmentViewState] = [],
        streaming: MessageStreamingState = .idle
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentId = parentId
        self.branchLeafId = branchLeafId ?? id
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
        branchLeafId = id
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

struct ConversationSummaryViewState: Equatable, Identifiable, Sendable {
    var id: String { sessionId }

    let sessionId: String
    var title: String
    var activeLeafId: String?
    var lastEventId: String?
    var lastUpdatedSequence: UInt64
    var lastMessageDate: Date? = nil
    var searchText: String = ""
}

struct ConversationListViewState: Equatable, Sendable {
    var conversations: [ConversationSummaryViewState]
    var isPresented: Bool
    var errorMessage: String?

    init(
        conversations: [ConversationSummaryViewState] = [],
        isPresented: Bool = false,
        errorMessage: String? = nil
    ) {
        self.conversations = conversations
        self.isPresented = isPresented
        self.errorMessage = errorMessage
    }
}

struct ConversationSectionViewState: Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var conversations: [ConversationSummaryViewState]
}

struct PromptSectionViewState: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var content: String
}

struct PromptLibraryViewState: Equatable, Sendable {
    var sections: [PromptSectionViewState]

    init(
        sections: [PromptSectionViewState] = [
            PromptSectionViewState(id: "system", name: "System Prompt", content: ""),
            PromptSectionViewState(id: "style", name: "Response Style", content: ""),
        ]
    ) {
        self.sections = sections
    }

    var renderedSystemPrompt: String {
        let rendered = sections.compactMap { section in
            let content = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return nil
            }
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? "Prompt" : name
            return "### \(title)\n\(content)"
        }
        .joined(separator: "\n\n")

        return rendered.isEmpty ? AgentPromptDefaults.systemPrompt : rendered
    }
}

struct ModelSettingsViewState: Equatable, Sendable {
    var temperature: Double
    var topP: Double

    init(temperature: Double = 0.7, topP: Double = 0.9) {
        self.temperature = temperature
        self.topP = topP
    }
}

struct AgentViewState: Equatable, Sendable {
    var phase: AppRuntimePhase
    var messages: [AgentMessageViewState]
    var draft: UserDraftViewState
    var currentSessionId: String?
    var errorMessage: String?
    var provider: ProviderSelectionViewState
    var conversations: ConversationListViewState
    var lastTerminalReason: RunTerminalReason?
    var lastAppliedRuntimeSequence: UInt64
    var lastAppliedExecutionSequenceByRunId: [String: UInt64]
    var transientRunEvents: [RuntimeEventDTO]
    var promptLibrary: PromptLibraryViewState
    var modelSettings: ModelSettingsViewState
    var selectedAgentProfileId: String
    var selectedAgentProfileRevisionId: UInt64?
    var pendingApprovalRequest: ApprovalProtocolRequestDTO?

    init(
        phase: AppRuntimePhase = .booting,
        messages: [AgentMessageViewState] = [],
        draft: UserDraftViewState = UserDraftViewState(),
        currentSessionId: String? = nil,
        errorMessage: String? = nil,
        provider: ProviderSelectionViewState = ProviderSelectionViewState(),
        conversations: ConversationListViewState = ConversationListViewState(),
        lastTerminalReason: RunTerminalReason? = nil,
        lastAppliedRuntimeSequence: UInt64 = 0,
        lastAppliedExecutionSequenceByRunId: [String: UInt64] = [:],
        transientRunEvents: [RuntimeEventDTO] = [],
        promptLibrary: PromptLibraryViewState = PromptLibraryViewState(),
        modelSettings: ModelSettingsViewState = ModelSettingsViewState(),
        selectedAgentProfileId: String = "profile_1",
        selectedAgentProfileRevisionId: UInt64? = 1,
        pendingApprovalRequest: ApprovalProtocolRequestDTO? = nil
    ) {
        self.phase = phase
        self.messages = messages
        self.draft = draft
        self.currentSessionId = currentSessionId
        self.errorMessage = errorMessage
        self.provider = provider
        self.conversations = conversations
        self.lastTerminalReason = lastTerminalReason
        self.lastAppliedRuntimeSequence = lastAppliedRuntimeSequence
        self.lastAppliedExecutionSequenceByRunId = lastAppliedExecutionSequenceByRunId
        self.transientRunEvents = transientRunEvents
        self.promptLibrary = promptLibrary
        self.modelSettings = modelSettings
        self.selectedAgentProfileId = selectedAgentProfileId
        self.selectedAgentProfileRevisionId = selectedAgentProfileRevisionId
        self.pendingApprovalRequest = pendingApprovalRequest
    }

    init(
        phase: AppRuntimePhase = .booting,
        messages: [AgentMessageViewState] = [],
        draft: String,
        currentSessionId: String? = nil,
        errorMessage: String? = nil,
        provider: ProviderSelectionViewState = ProviderSelectionViewState(),
        conversations: ConversationListViewState = ConversationListViewState(),
        lastTerminalReason: RunTerminalReason? = nil,
        promptLibrary: PromptLibraryViewState = PromptLibraryViewState(),
        modelSettings: ModelSettingsViewState = ModelSettingsViewState(),
        selectedAgentProfileId: String = "profile_1",
        selectedAgentProfileRevisionId: UInt64? = 1,
        pendingApprovalRequest: ApprovalProtocolRequestDTO? = nil
    ) {
        self.init(
            phase: phase,
            messages: messages,
            draft: UserDraftViewState(text: draft),
            currentSessionId: currentSessionId,
            errorMessage: errorMessage,
            provider: provider,
            conversations: conversations,
            lastTerminalReason: lastTerminalReason,
            promptLibrary: promptLibrary,
            modelSettings: modelSettings,
            selectedAgentProfileId: selectedAgentProfileId,
            selectedAgentProfileRevisionId: selectedAgentProfileRevisionId,
            pendingApprovalRequest: pendingApprovalRequest
        )
    }

    var draftText: String {
        get { draft.text }
        set { draft.text = newValue }
    }

    var executionOptions: ExecutionOptionsDTO {
        ExecutionOptionsDTO(
            temperature: modelSettings.temperature,
            topP: modelSettings.topP
        )
    }

    mutating func finishStreamingMessages(as terminalState: MessageStreamingState) {
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].streaming = terminalState
        }
    }
}
