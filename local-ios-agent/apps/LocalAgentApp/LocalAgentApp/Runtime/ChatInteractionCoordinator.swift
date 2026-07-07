import Foundation
import LocalAgentBridge

struct ChatInteractionResult: Equatable, Sendable {
    var runId: String
    var state: RunStateDTO
}

protocol ChatInteractionCoordinating: AnyObject, Sendable {
    @MainActor
    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        agentProfileRevisionId: UInt64,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> ChatInteractionResult
}

final class ChatInteractionCoordinator: ChatInteractionCoordinating {
    private let conversation: any ConversationDomain
    private let execution: any ExecutionDomain
    private let toolDriver: MinimalHostToolDriver

    init(
        conversation: any ConversationDomain,
        execution: any ExecutionDomain,
        toolDriver: MinimalHostToolDriver = MinimalHostToolDriver()
    ) {
        self.conversation = conversation
        self.execution = execution
        self.toolDriver = toolDriver
    }

    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        agentProfileRevisionId: UInt64,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void = { _ in }
    ) async throws -> ChatInteractionResult {
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
                profileRevisionId: agentProfileRevisionId,
                userIntent: text,
                conversationRunFrameRef: preparedTurn.conversationRunFrameRef,
                options: options
            )
        )

        return try await driveRun(
            runId: handle.runId,
            replayFromSequence: handle.replayFromSequence,
            preparedTurn: preparedTurn,
            onEvent: onEvent
        )
    }

    private func driveRun(
        runId: String,
        replayFromSequence: UInt64,
        preparedTurn: PreparedUserTurnDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> ChatInteractionResult {
        var fromSequence = replayFromSequence
        var continuationIndex = 0

        while true {
            let observed = try await observeRunBoundary(
                runId: runId,
                fromSequence: fromSequence,
                preparedTurn: preparedTurn,
                onEvent: onEvent
            )
            fromSequence = observed.lastSequence ?? fromSequence

            switch observed.state {
            case .completed:
                if let finalMessageId = observed.finalMessageId {
                    let commit = try await commitCompletedRun(
                        runId: runId,
                        finalMessageId: finalMessageId,
                        frameRef: preparedTurn.conversationRunFrameRef
                    )
                    if let finalAssistantEvent = observed.finalAssistantEvent {
                        await onEvent(finalAssistantEvent.withConversationEventId(commit.committedMessageId))
                    }
                }
                return ChatInteractionResult(runId: runId, state: .completed)
            case .waitingTool:
                guard let pendingToolCallId = observed.pendingToolCallId,
                      let request = try await pendingToolRequest(
                        runId: runId,
                        toolCallId: pendingToolCallId
                      ),
                      let result = await toolDriver.execute(request, continuationIndex: continuationIndex)
                else {
                    return ChatInteractionResult(runId: runId, state: .waitingTool)
                }
                _ = try await execution.submitToolResult(runId: request.runId, result: result)
                continuationIndex += 1
            case .suspended:
                return ChatInteractionResult(runId: runId, state: .suspended)
            case .failed:
                return ChatInteractionResult(runId: runId, state: .failed)
            case .cancelled:
                return ChatInteractionResult(runId: runId, state: .cancelled)
            default:
                return ChatInteractionResult(runId: runId, state: observed.state)
            }
        }
    }

    private struct ObservedRunBoundary {
        var state: RunStateDTO = .running
        var lastSequence: UInt64?
        var finalMessageId: String?
        var finalAssistantEvent: RuntimeEventDTO?
        var pendingToolCallId: String?
    }

    private func observeRunBoundary(
        runId: String,
        fromSequence: UInt64,
        preparedTurn: PreparedUserTurnDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> ObservedRunBoundary {
        var observed = ObservedRunBoundary()
        for try await event in execution.observeEvents(
            runId: runId,
            fromSequence: fromSequence
        ) {
            if event.sequence > 0 {
                observed.lastSequence = max(observed.lastSequence ?? 0, event.sequence)
            }
            observed.pendingToolCallId = event.pendingToolCallId ?? observed.pendingToolCallId
            observed.state = event.runBoundaryState ?? observed.state
            let projectedEvent = event.projectedConversationEvent(
                sessionId: preparedTurn.sessionId,
                parentId: preparedTurn.userMessageId
            )
            if let messageId = event.finalAssistantMessageId {
                observed.finalMessageId = messageId
                observed.finalAssistantEvent = projectedEvent
                observed.state = .completed
            } else {
                await onEvent(projectedEvent)
            }
        }

        return observed
    }

    private func pendingToolRequest(
        runId: String,
        toolCallId: String
    ) async throws -> ToolExecutionRequestDTO? {
        let pending = try await execution.pendingToolRequests()
        return pending.first { request in
            request.runId == runId && request.toolCallId == toolCallId
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

    var pendingToolCallId: String? {
        guard kind == .toolCallRequested else {
            return nil
        }
        return payloadString("tool_call_id") ?? payloadString("id")
    }

    var runBoundaryState: RunStateDTO? {
        switch kind {
        case .runWaitingTool:
            return .waitingTool
        case .runSuspended:
            return .suspended
        case .runCancelled:
            return .cancelled
        case .runFailed:
            return .failed
        default:
            switch kind.rawValue {
            case "run_waiting_tool":
                return .waitingTool
            case "run_suspended":
                return .suspended
            case "run_cancelled":
                return .cancelled
            case "run_failed":
                return .failed
            default:
                return nil
            }
        }
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
