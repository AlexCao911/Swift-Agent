import Combine
import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var sessions: [ChatSession]
    @Published private(set) var messagesByConversation: [String: [ChatMessage]]
    @Published private(set) var activeRunIDByConversation: [String: String] = [:]

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

    func activeRunID(conversationStreamID: String) -> String? {
        activeRunIDByConversation[conversationStreamID]
    }

    func markRunAccepted(
        conversationStreamID: String,
        runID: String
    ) {
        activeRunIDByConversation[conversationStreamID] = runID
    }

    func retryAnchorEventID(
        forAssistantMessageID assistantMessageID: String,
        conversationStreamID: String
    ) -> String? {
        let messages = messagesByConversation[conversationStreamID, default: []]
        guard let assistantIndex = messages.firstIndex(where: {
            $0.id == assistantMessageID && $0.role == .assistant
        }) else {
            return nil
        }
        return messages[..<assistantIndex]
            .last(where: { $0.role == .user })?
            .id
    }

    func resetProjection(conversationStreamID: String) {
        messagesByConversation[conversationStreamID] = []
        activeRunIDByConversation.removeValue(forKey: conversationStreamID)
    }

    func restoreSessions(_ summaries: [ConversationSummaryDTO]) {
        var restored = Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.sessionId, $0)
        })
        for summary in summaries {
            restored[summary.sessionId] = ConversationSummaryViewState(
                sessionId: summary.sessionId,
                title: summary.title,
                activeLeafId: summary.activeLeafId,
                lastEventId: summary.lastEventId,
                lastUpdatedSequence: summary.lastUpdatedSequence,
                lastMessageDate: summary.lastUpdatedAtMillis.flatMap {
                    $0 == 0 ? nil : Date(
                        timeIntervalSince1970: TimeInterval($0) / 1_000
                    )
                },
                searchText: summary.searchText ?? ""
            )
        }
        sessions = Array(restored.values)
    }

    func applyProjection(_ event: TranscriptProjectionEventDTO) {
        let streamID = event.conversationStreamID
        ensureSession(streamID)
        switch event.kind {
        case .userMessage:
            let attachments = projectionAttachments(
                event.payload,
                key: "attachments"
            )
            upsertMessage(
                ChatMessage(
                    id: event.eventID,
                    sessionId: streamID,
                    role: .user,
                    parts: textParts(projectionCommand(event.payload, key: "text")),
                    attachments: attachments
                ),
                in: streamID
            )
        case .assistantMessageStarted:
            guard let runID = event.runID else { break }
            activeRunIDByConversation[streamID] = runID
            upsertMessage(streamingMessage(runID: runID, streamID: streamID), in: streamID)
        case .assistantTextDelta:
            guard let runID = event.runID else { break }
            activeRunIDByConversation[streamID] = runID
            appendStreamingText(
                projectionText(event.payload),
                runID: runID,
                streamID: streamID
            )
        case .assistantMessageCompleted:
            removeStreamingMessage(runID: event.runID, streamID: streamID)
            upsertMessage(
                ChatMessage(
                    id: event.eventID,
                    sessionId: streamID,
                    role: .assistant,
                    parts: textParts(projectionText(event.payload))
                ),
                in: streamID
            )
            if event.eventID.hasSuffix("-final") {
                activeRunIDByConversation.removeValue(forKey: streamID)
            }
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
            replaceMessageAndDiscardDescendants(
                target,
                with: ChatMessage(
                    id: event.eventID,
                    sessionId: streamID,
                    role: .user,
                    parts: textParts(replacement),
                    attachments: projectionAttachments(
                        event.payload,
                        key: "replacement_attachments"
                    )
                ),
                in: streamID
            )
        case .messageDeleted:
            discardMessageAndDescendants(
                projectionCommand(event.payload, key: "target_event_id"),
                in: streamID
            )
        case .conversationCleared:
            messagesByConversation[streamID] = []
            activeRunIDByConversation.removeValue(forKey: streamID)
        case .conversationArchived:
            sessions.removeAll { $0.sessionId == streamID }
        case .conversationDeleted:
            sessions.removeAll { $0.sessionId == streamID }
            messagesByConversation.removeValue(forKey: streamID)
            activeRunIDByConversation.removeValue(forKey: streamID)
        case .branchCreated:
            let branch = projectionCommand(
                event.payload,
                key: "new_conversation_stream_id"
            )
            if !branch.isEmpty {
                ensureSession(branch)
            }
        case .transcriptRetryRequested:
            discardDescendants(
                after: projectionCommand(event.payload, key: "anchor_event_id"),
                in: streamID
            )
        case .runCancelled:
            finishStreamingRun(event, state: .cancelled)
        case .runFailed:
            finishStreamingRun(
                event,
                state: .failed(projectionFailureCode(event.payload))
            )
        case .sessionCreated, .providerChanged, .toolRegistered,
             .toolCallApproved, .toolCallRejected,
             .toolExecutionStarted, .toolExecutionUpdate,
             .toolExecutionCompleted, .toolExecutionFailed,
             .runSuspended, .runResumed, .compactionCreated,
             .branchSummaryCreated:
            break
        }
        if event.sequence > 0 {
            touchSession(
                streamID,
                sequence: event.sequence,
                eventID: event.eventID
            )
        }
    }

    private func streamingMessage(runID: String, streamID: String) -> ChatMessage {
        ChatMessage(
            id: streamingMessageID(runID),
            sessionId: streamID,
            role: .assistant,
            parts: [],
            streaming: .streaming
        )
    }

    private func appendStreamingText(
        _ text: String,
        runID: String,
        streamID: String
    ) {
        let id = streamingMessageID(runID)
        var messages = messagesByConversation[streamID, default: []]
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
            messages[index].streaming = .streaming
        } else {
            var message = streamingMessage(runID: runID, streamID: streamID)
            message.text = text
            messages.append(message)
        }
        messagesByConversation[streamID] = messages
    }

    private func removeStreamingMessage(runID: String?, streamID: String) {
        guard let runID else { return }
        messagesByConversation[streamID]?.removeAll {
            $0.id == streamingMessageID(runID)
        }
    }

    private func finishStreamingRun(
        _ event: TranscriptProjectionEventDTO,
        state: MessageStreamingState
    ) {
        guard let runID = event.runID else { return }
        let id = streamingMessageID(runID)
        if let index = messagesByConversation[event.conversationStreamID]?
            .firstIndex(where: { $0.id == id }) {
            messagesByConversation[event.conversationStreamID]?[index].streaming = state
        }
        if activeRunIDByConversation[event.conversationStreamID] == runID {
            activeRunIDByConversation.removeValue(
                forKey: event.conversationStreamID
            )
        }
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

    private func replaceMessageAndDiscardDescendants(
        _ id: String,
        with replacement: ChatMessage,
        in streamID: String
    ) {
        guard !id.isEmpty,
              var messages = messagesByConversation[streamID],
              let index = messages.firstIndex(where: { $0.id == id })
        else { return }
        messages.replaceSubrange(index..., with: [replacement])
        messagesByConversation[streamID] = messages
    }

    private func discardMessageAndDescendants(
        _ id: String,
        in streamID: String
    ) {
        guard !id.isEmpty,
              var messages = messagesByConversation[streamID],
              let index = messages.firstIndex(where: { $0.id == id })
        else { return }
        messages.removeSubrange(index...)
        messagesByConversation[streamID] = messages
    }

    private func discardDescendants(after id: String, in streamID: String) {
        guard !id.isEmpty,
              var messages = messagesByConversation[streamID],
              let index = messages.firstIndex(where: { $0.id == id }),
              messages.index(after: index) < messages.endIndex
        else { return }
        messages.removeSubrange(messages.index(after: index)...)
        messagesByConversation[streamID] = messages
    }
}

private func streamingMessageID(_ runID: String) -> String {
    "streaming-\(runID)"
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

private func projectionAttachments(
    _ payload: CanonicalJSONValue,
    key: String
) -> [AttachmentViewState] {
    guard let command = payload.objectValue(forKey: "command"),
          case let .array(values)? = command.objectValue(forKey: key)
    else { return [] }
    return values.compactMap { value in
        guard case let .string(id)? = value.objectValue(forKey: "attachment_id"),
              case let .string(name)? = value.objectValue(forKey: "display_name"),
              case let .string(mediaType)? = value.objectValue(forKey: "media_type"),
              case let .string(modality)? = value.objectValue(forKey: "modality")
        else { return nil }
        return AttachmentViewState(
            id: id,
            kind: AttachmentKindViewState(rawValue: modality)
                ?? (mediaType.hasPrefix("image/") ? .image : .file),
            displayName: name,
            localPath: nil,
            urlString: nil,
            mimeType: mediaType,
            byteCount: nil
        )
    }
}

private func projectionFailureCode(_ payload: CanonicalJSONValue) -> String {
    guard case let .string(code)? = payload.objectValue(forKey: "code") else {
        return "Agent run failed"
    }
    return code
}
