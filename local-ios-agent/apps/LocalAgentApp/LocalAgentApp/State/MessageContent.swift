enum MessagePartViewState: Equatable, Identifiable, Sendable {
    case text(TextPartViewState)
    case reasoning(ReasoningPartViewState)
    case tool(ToolPartViewState)
    case error(ErrorPartViewState)
    case attachment(AttachmentViewState)

    var id: String {
        switch self {
        case let .text(part):
            part.id
        case let .reasoning(part):
            part.id
        case let .tool(part):
            part.id
        case let .error(part):
            part.id
        case let .attachment(part):
            part.id
        }
    }

    var plainText: String {
        switch self {
        case let .text(part):
            part.text
        case let .reasoning(part):
            part.text
        case let .tool(part):
            part.displayText
        case let .error(part):
            part.message
        case let .attachment(part):
            part.displayName
        }
    }
}

struct TextPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var text: String
}

struct ReasoningPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var isCollapsed: Bool
    var isStreaming: Bool
}

struct ToolPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var displayText: String
}

struct ErrorPartViewState: Equatable, Identifiable, Sendable {
    let id: String
    var message: String
}

enum MessageStreamingState: Equatable, Sendable {
    case idle
    case streaming
    case cancelled
    case failed(String)
    case reachedLimit

    var isStreaming: Bool {
        if case .streaming = self {
            return true
        }
        return false
    }
}

enum AttachmentKindViewState: String, Equatable, Sendable {
    case image
    case link
}

struct AttachmentViewState: Equatable, Identifiable, Sendable {
    let id: String
    var kind: AttachmentKindViewState
    var displayName: String
    var localPath: String?
    var urlString: String?
    var mimeType: String?
    var byteCount: Int?
}

extension AttachmentViewState {
    init(draft: AttachmentDraftViewState) {
        self.init(
            id: draft.id,
            kind: draft.kind,
            displayName: draft.displayName,
            localPath: draft.localPath,
            urlString: draft.urlString,
            mimeType: draft.mimeType,
            byteCount: draft.byteCount
        )
    }
}

struct AttachmentDraftViewState: Equatable, Identifiable, Sendable {
    let id: String
    var kind: AttachmentKindViewState
    var displayName: String
    var localPath: String?
    var urlString: String?
    var mimeType: String?
    var byteCount: Int?
}

struct UserDraftViewState: Equatable, Sendable {
    var text: String
    var attachments: [AttachmentDraftViewState]
    var targetParentEventId: String?

    init(
        text: String = "",
        attachments: [AttachmentDraftViewState] = [],
        targetParentEventId: String? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.targetParentEventId = targetParentEventId
    }
}
