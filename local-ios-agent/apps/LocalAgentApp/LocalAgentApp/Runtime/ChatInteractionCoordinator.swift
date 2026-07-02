import Foundation
import LocalAgentBridge

protocol ChatInteractionCoordinating: AnyObject, Sendable {
    @MainActor
    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws
}

final class ChatInteractionCoordinator: ChatInteractionCoordinating {
    private let conversation: any ConversationDomain
    private let execution: any ExecutionDomain

    init(
        conversation: any ConversationDomain,
        execution: any ExecutionDomain
    ) {
        self.conversation = conversation
        self.execution = execution
    }

    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void = { _ in }
    ) async throws {
        let preparedTurn = try await conversation.prepareUserTurn(
            PrepareUserTurnRequestDTO(
                sessionId: sessionId,
                parentEventId: parentEventId,
                text: text
            )
        )
        await onEvent(preparedTurn.userMessageEvent(text: text, parentEventId: parentEventId))
        let handle = try await execution.startRun(
            StartExecutionRequestDTO(
                agentProfileId: agentProfileId,
                userIntent: text,
                conversationRunFrameRef: preparedTurn.conversationRunFrameRef,
                options: options
            )
        )

        var finalMessageId: String?
        var finalAssistantEvent: RuntimeEventDTO?
        for try await event in execution.observeEvents(
            runId: handle.runId,
            fromSequence: handle.replayFromSequence
        ) {
            let projectedEvent = event.projectedConversationEvent(
                sessionId: preparedTurn.sessionId,
                parentId: preparedTurn.userMessageId
            )
            if let messageId = event.finalAssistantMessageId {
                finalMessageId = messageId
                finalAssistantEvent = projectedEvent
            } else {
                await onEvent(projectedEvent)
            }
        }

        if let finalMessageId {
            let commit = try await commitCompletedRun(
                runId: handle.runId,
                finalMessageId: finalMessageId,
                frameRef: preparedTurn.conversationRunFrameRef
            )
            if let finalAssistantEvent {
                await onEvent(finalAssistantEvent.withConversationEventId(commit.committedMessageId))
            }
        }
    }

    func recoverCompletedRunCommit(
        runId: String,
        finalMessageId: String,
        frameRef: ConversationRunFrameRefDTO
    ) async throws {
        _ = try await commitCompletedRun(
            runId: runId,
            finalMessageId: finalMessageId,
            frameRef: frameRef
        )
    }

    private func commitCompletedRun(
        runId: String,
        finalMessageId: String,
        frameRef: ConversationRunFrameRefDTO
    ) async throws -> ConversationCommitResultDTO {
        try await conversation.commitAssistantResult(
            CommitAssistantResultRequestDTO(
                runId: runId,
                finalMessageId: finalMessageId,
                conversationRunFrameRef: frameRef
            )
        )
    }

    func approveTool(id: String, decision: ApprovalDecisionDTO) async throws {
        try await execution.approveTool(id: id, decision: decision)
    }

    func cancelRun(runId: String) async throws {
        _ = try await execution.cancelRun(runId: runId)
    }
}

private extension PreparedUserTurnDTO {
    func userMessageEvent(text: String, parentEventId: String?) -> RuntimeEventDTO {
        let parentId = normalizedParentEventId(parentEventId)
            ?? (conversationRunFrameRef.branchHeadId == userMessageId ? nil : conversationRunFrameRef.branchHeadId)
        return RuntimeEventDTO(
            id: userMessageId,
            sessionId: sessionId,
            parentId: parentId,
            runId: nil,
            sequence: 0,
            depth: 0,
            kind: .userMessage,
            payload: text,
            blobRefs: []
        )
    }

    private func normalizedParentEventId(_ parentEventId: String?) -> String? {
        guard parentEventId != "__local_agent_root__" else {
            return nil
        }
        return parentEventId
    }
}

private extension RuntimeEventDTO {
    var finalAssistantMessageId: String? {
        guard kind == .assistantMessageCompleted else {
            return nil
        }
        return payloadString("message_id") ?? id
    }

    func payloadString(_ key: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object[key] as? String
    }

    func projectedConversationEvent(sessionId: String, parentId: String) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: self.sessionId.isEmpty ? sessionId : self.sessionId,
            parentId: self.parentId ?? parentId,
            runId: runId,
            sequence: 0,
            depth: depth,
            kind: kind,
            payload: payload,
            blobRefs: blobRefs
        )
    }

    func withConversationEventId(_ id: String) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: sessionId,
            parentId: parentId,
            runId: runId,
            sequence: sequence,
            depth: depth,
            kind: kind,
            payload: payloadReplacingMessageId(id),
            blobRefs: blobRefs
        )
    }

    private func payloadReplacingMessageId(_ messageId: String) -> String {
        guard let data = payload.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return payload
        }
        object["message_id"] = messageId
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: encoded, encoding: .utf8)
        else {
            return payload
        }
        return string
    }
}
