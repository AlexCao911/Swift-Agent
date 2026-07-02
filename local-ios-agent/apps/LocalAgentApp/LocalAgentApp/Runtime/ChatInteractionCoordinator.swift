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

@MainActor
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
        let handle = try await execution.startRun(
            StartExecutionRequestDTO(
                agentProfileId: agentProfileId,
                userIntent: text,
                conversationRunFrameRef: preparedTurn.conversationRunFrameRef,
                options: options
            )
        )

        var finalMessageId: String?
        for try await event in execution.observeEvents(
            runId: handle.runId,
            fromSequence: handle.replayFromSequence
        ) {
            await onEvent(event)
            if let messageId = event.finalAssistantMessageId {
                finalMessageId = messageId
            }
        }

        if let finalMessageId {
            try await recoverCompletedRunCommit(
                runId: handle.runId,
                finalMessageId: finalMessageId,
                frameRef: preparedTurn.conversationRunFrameRef
            )
        }
    }

    func recoverCompletedRunCommit(
        runId: String,
        finalMessageId: String,
        frameRef: ConversationRunFrameRefDTO
    ) async throws {
        _ = try await conversation.commitAssistantResult(
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
}
