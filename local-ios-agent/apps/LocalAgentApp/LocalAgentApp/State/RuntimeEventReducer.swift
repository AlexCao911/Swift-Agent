import Foundation
import LocalAgentBridge

enum RuntimeEventReducer {
    static func apply(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
        if event.sequence > 0 {
            guard event.sequence > lastAppliedSequence(for: event, in: state) else {
                return
            }
        }

        switch event.kind {
        case .sessionCreated:
            state.currentSessionId = event.sessionId
        case .userMessage:
            appendUserMessage(event, to: &state)
        case .assistantMessageStarted:
            startAssistantMessage(event, in: &state)
        case .assistantTextDelta:
            appendAssistantDelta(event, to: &state)
        case .assistantMessageCompleted:
            completeAssistantMessage(event, in: &state)
        case .toolCallRequested:
            state.phase = event.runId.map(AppRuntimePhase.running) ?? state.phase
        case .toolResultMessage:
            appendToolResult(event, to: &state)
        case .runCancelled:
            state.phase = .ready
            state.errorMessage = nil
            state.lastTerminalReason = .cancelled
            state.finishStreamingMessages(as: .cancelled)
        case .runFailed:
            let message = payloadString("message", from: event.payload) ?? event.payload
            state.phase = .failed(message: message)
            state.errorMessage = message
            state.lastTerminalReason = .failed(message)
            state.finishStreamingMessages(as: .failed(message))
        default:
            break
        }

        if event.clearsPendingApprovalRequest {
            state.pendingApprovalRequest = nil
        }

        updateTransientRunEvents(with: event, in: &state)

        if event.sequence > 0 {
            recordAppliedSequence(event, in: &state)
        }
    }

    private static func lastAppliedSequence(for event: RuntimeEventDTO, in state: AgentViewState) -> UInt64 {
        guard let runId = executionRunSequenceScope(for: event) else {
            return state.lastAppliedRuntimeSequence
        }
        return state.lastAppliedExecutionSequenceByRunId[runId] ?? 0
    }

    private static func recordAppliedSequence(_ event: RuntimeEventDTO, in state: inout AgentViewState) {
        guard let runId = executionRunSequenceScope(for: event) else {
            state.lastAppliedRuntimeSequence = event.sequence
            return
        }
        state.lastAppliedExecutionSequenceByRunId[runId] = event.sequence
    }

    private static func executionRunSequenceScope(for event: RuntimeEventDTO) -> String? {
        guard event.sessionId.isEmpty else {
            return nil
        }
        return event.runId
    }

    private static func updateTransientRunEvents(
        with event: RuntimeEventDTO,
        in state: inout AgentViewState
    ) {
        if event.clearsTransientRunCardEvents {
            state.transientRunEvents = []
            return
        }

        guard event.isTransientRunCardEvent else {
            return
        }

        state.transientRunEvents.removeAll { $0.id == event.id }
        state.transientRunEvents.append(event)
        if state.transientRunEvents.count > 20 {
            state.transientRunEvents.removeFirst(state.transientRunEvents.count - 20)
        }
    }

    private static func appendUserMessage(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
        guard !state.messages.contains(where: { $0.id == event.id }) else {
            return
        }
        let decoded = RuntimeBlobRefCodec.decodeUserMessage(from: event.blobRefs)
        let text = decoded.text ?? event.payload
        state.messages.append(AgentMessageViewState(
            id: event.id,
            sessionId: event.sessionId,
            parentId: event.parentId,
            branchLeafId: event.id,
            role: .user,
            parts: text.isEmpty ? [] : [.text(TextPartViewState(id: "\(event.id)_text_0", text: text))],
            attachments: decoded.attachments,
            streaming: .idle
        ))
    }

    private static func startAssistantMessage(_ event: RuntimeEventDTO, in state: inout AgentViewState) {
        let messageId = assistantMessageId(for: event, in: state)
        guard !state.messages.contains(where: { $0.id == messageId }) else {
            return
        }

        state.messages.append(AgentMessageViewState(
            id: messageId,
            sessionId: event.sessionId,
            parentId: event.parentId,
            branchLeafId: event.id,
            role: .assistant,
            parts: [],
            streaming: .streaming
        ))
    }

    private static func appendAssistantDelta(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
        let text = payloadString("text", from: event.payload) ?? event.payload
        let messageId = assistantMessageId(for: event, in: state)
        if let index = state.messages.firstIndex(where: { $0.id == messageId }) {
            state.messages[index].streaming = .streaming
            state.messages[index].text += text
        } else {
            var message = AgentMessageViewState(
                id: messageId,
                sessionId: event.sessionId,
                parentId: event.parentId,
                branchLeafId: event.id,
                role: .assistant,
                parts: [],
                streaming: .streaming
            )
            message.text += text
            state.messages.append(message)
        }
    }

    private static func completeAssistantMessage(_ event: RuntimeEventDTO, in state: inout AgentViewState) {
        let messageId = assistantMessageId(for: event, in: state)
        let completedText = payloadString("text", from: event.payload) ?? event.payload

        if let index = state.messages.firstIndex(where: { $0.id == messageId }) {
            state.messages[index].text = completedText
            state.messages[index].isStreaming = false
            state.messages[index].branchLeafId = event.id
        } else {
            state.messages.append(AgentMessageViewState(
                id: messageId,
                sessionId: event.sessionId,
                parentId: event.parentId,
                branchLeafId: event.id,
                role: .assistant,
                parts: parsedAssistantParts(from: completedText, isFinal: true),
                streaming: .idle
            ))
        }
    }

    private static func appendToolResult(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
        guard !state.messages.contains(where: { $0.id == event.id }) else {
            return
        }

        let displayText = payloadString("display_text", from: event.payload) ?? event.payload
        state.messages.append(AgentMessageViewState(
            id: event.id,
            sessionId: event.sessionId,
            parentId: event.parentId,
            branchLeafId: event.id,
            role: .tool,
            parts: [.tool(ToolPartViewState(id: event.id, displayText: displayText))],
            streaming: .idle
        ))
    }

    private static func parsedAssistantParts(from text: String, isFinal: Bool) -> [MessagePartViewState] {
        var parser = ReasoningTagParser()
        parser.append(text)
        return isFinal ? parser.finish() : parser.snapshot(isFinal: false)
    }

    private static func assistantMessageId(for event: RuntimeEventDTO, in state: AgentViewState) -> String {
        if let messageId = payloadString("message_id", from: event.payload) {
            return messageId
        }
        if let lastAssistant = state.messages.last(where: { $0.role == .assistant && $0.isStreaming }) {
            return lastAssistant.id
        }
        if event.kind == .assistantMessageStarted {
            return event.id
        }
        return state.messages.last(where: { $0.role == .assistant })?.id ?? event.id
    }

    private static func payloadString(_ key: String, from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object[key] as? String
    }
}

private extension RuntimeEventDTO {
    var isTransientRunCardEvent: Bool {
        kind == .runSuspended
            || kind == .runWaitingTool
            || kind == .toolExecutionFailed
            || kind == .runFailed
    }

    var clearsTransientRunCardEvents: Bool {
        kind == .assistantMessageCompleted || kind == .runCancelled
    }

    var clearsPendingApprovalRequest: Bool {
        kind == .assistantMessageCompleted
            || kind == .runCancelled
            || kind == .runFailed
            || kind == .toolCallApproved
            || kind == .toolCallRejected
    }
}
