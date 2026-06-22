import Foundation

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

enum RuntimeBlobRefCodec {
    private static let prefix = "local-agent-chat:v1:"

    private struct Payload: Codable {
        var type: String
        var text: String?
        var id: String?
        var kind: String?
        var displayName: String?
        var localPath: String?
        var urlString: String?
        var mimeType: String?
        var byteCount: Int?
    }

    static func encodeUserMessage(
        text: String,
        attachments: [AttachmentDraftViewState]
    ) -> [String] {
        guard !attachments.isEmpty else {
            return []
        }

        let metadata = Payload(type: "user_message_metadata", text: text)
        return ([metadata] + attachments.map(Self.payload)).compactMap(encode)
    }

    static func decodeUserMessage(from blobRefs: [String]) -> (text: String?, attachments: [AttachmentViewState]) {
        var text: String?
        var attachments: [AttachmentViewState] = []

        for payload in blobRefs.compactMap(decode) {
            switch payload.type {
            case "user_message_metadata":
                text = payload.text
            case "attachment":
                guard let attachment = attachment(from: payload) else {
                    continue
                }
                attachments.append(attachment)
            default:
                continue
            }
        }

        return (text, attachments)
    }

    private static func payload(from attachment: AttachmentDraftViewState) -> Payload {
        Payload(
            type: "attachment",
            id: attachment.id,
            kind: attachment.kind.rawValue,
            displayName: attachment.displayName,
            localPath: attachment.localPath,
            urlString: attachment.urlString,
            mimeType: attachment.mimeType,
            byteCount: attachment.byteCount
        )
    }

    private static func attachment(from payload: Payload) -> AttachmentViewState? {
        guard let id = payload.id,
              let rawKind = payload.kind,
              let kind = AttachmentKindViewState(rawValue: rawKind),
              let displayName = payload.displayName
        else {
            return nil
        }

        return AttachmentViewState(
            id: id,
            kind: kind,
            displayName: displayName,
            localPath: payload.localPath,
            urlString: payload.urlString,
            mimeType: payload.mimeType,
            byteCount: payload.byteCount
        )
    }

    private static func encode(_ payload: Payload) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return prefix + base64URLEncodedString(from: data)
    }

    private static func decode(_ blobRef: String) -> Payload? {
        guard blobRef.hasPrefix(prefix) else {
            return nil
        }
        let encoded = String(blobRef.dropFirst(prefix.count))
        guard let data = data(fromBase64URL: encoded) else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func base64URLEncodedString(from data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func data(fromBase64URL encoded: String) -> Data? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
