import Combine
import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var sessions: [ChatSession]
    @Published private(set) var messagesByConversation: [String: [ChatMessage]]

    init(
        sessions: [ChatSession] = [],
        messagesByConversation: [String: [ChatMessage]] = [:]
    ) {
        self.sessions = sessions
        self.messagesByConversation = messagesByConversation
    }

    func projectedMessages(conversationStreamID: String) -> [ChatMessage] {
        messagesByConversation[conversationStreamID, default: []]
    }

    func resetProjection(conversationStreamID: String) {
        messagesByConversation[conversationStreamID] = []
    }

    func applyProjection(_ event: TranscriptProjectionEventDTO) {
        let streamID = event.conversationStreamID
        ensureSession(streamID)
        switch event.kind {
        case .userMessage:
            upsertMessage(
                ChatMessage(
                    id: event.eventID,
                    sessionId: streamID,
                    role: .user,
                    parts: textParts(projectionCommand(event.payload, key: "text"))
                ),
                in: streamID
            )
        case .assistantMessageCompleted:
            upsertMessage(
                ChatMessage(
                    id: event.eventID,
                    sessionId: streamID,
                    role: .assistant,
                    parts: textParts(projectionText(event.payload))
                ),
                in: streamID
            )
        case .toolCallRequested, .toolResultMessage:
            upsertMessage(
                ChatMessage(
                    id: event.eventID,
                    sessionId: streamID,
                    role: .tool,
                    parts: [.tool(ToolPartViewState(
                        id: event.eventID,
                        displayText: projectionText(event.payload)
                    ))]
                ),
                in: streamID
            )
        case .messageEdited:
            let target = projectionCommand(event.payload, key: "target_event_id")
            let replacement = projectionCommand(
                event.payload,
                key: "replacement_text"
            )
            updateMessage(target, in: streamID) { $0.text = replacement }
        case .messageDeleted:
            deleteMessage(
                projectionCommand(event.payload, key: "target_event_id"),
                in: streamID
            )
        case .conversationCleared:
            messagesByConversation[streamID] = []
        case .conversationArchived:
            sessions.removeAll { $0.sessionId == streamID }
        case .conversationDeleted:
            sessions.removeAll { $0.sessionId == streamID }
            messagesByConversation.removeValue(forKey: streamID)
        case .branchCreated:
            let branch = projectionCommand(
                event.payload,
                key: "new_conversation_stream_id"
            )
            if !branch.isEmpty {
                ensureSession(branch)
            }
        case .sessionCreated, .providerChanged, .toolRegistered,
             .transcriptRetryRequested, .assistantMessageStarted,
             .assistantTextDelta, .toolCallApproved, .toolCallRejected,
             .toolExecutionStarted, .toolExecutionUpdate,
             .toolExecutionCompleted, .toolExecutionFailed,
             .runSuspended, .runResumed, .compactionCreated,
             .branchSummaryCreated, .runCancelled, .runFailed:
            break
        }
        touchSession(streamID, sequence: event.sequence, eventID: event.eventID)
    }

    private func ensureSession(_ streamID: String) {
        guard !streamID.isEmpty,
              !sessions.contains(where: { $0.sessionId == streamID })
        else { return }
        sessions.append(ConversationSummaryViewState(
            sessionId: streamID,
            title: "New conversation",
            activeLeafId: nil,
            lastEventId: nil,
            lastUpdatedSequence: 0
        ))
    }

    private func touchSession(
        _ streamID: String,
        sequence: UInt64,
        eventID: String
    ) {
        guard let index = sessions.firstIndex(where: {
            $0.sessionId == streamID
        }) else { return }
        sessions[index].lastEventId = eventID
        sessions[index].lastUpdatedSequence = sequence
        sessions[index].lastMessageDate = Date()
    }

    private func upsertMessage(_ message: ChatMessage, in streamID: String) {
        var messages = messagesByConversation[streamID, default: []]
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messagesByConversation[streamID] = messages
    }

    private func updateMessage(
        _ id: String,
        in streamID: String,
        update: (inout ChatMessage) -> Void
    ) {
        guard !id.isEmpty,
              var messages = messagesByConversation[streamID],
              let index = messages.firstIndex(where: { $0.id == id })
        else { return }
        update(&messages[index])
        messagesByConversation[streamID] = messages
    }

    private func deleteMessage(_ id: String, in streamID: String) {
        messagesByConversation[streamID]?.removeAll { $0.id == id }
    }
}

private func textParts(_ text: String) -> [MessagePartViewState] {
    text.isEmpty ? [] : [.text(TextPartViewState(id: "text_0", text: text))]
}

private func projectionText(_ value: CanonicalJSONValue) -> String {
    if case let .string(text) = value {
        return text
    }
    guard let data = try? JSONEncoder().encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

private func projectionCommand(
    _ payload: CanonicalJSONValue,
    key: String
) -> String {
    guard let command = payload.objectValue(forKey: "command"),
          case let .string(value)? = command.objectValue(forKey: key)
    else { return "" }
    return value
}
