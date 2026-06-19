import Foundation
import LocalAgentBridge

enum RuntimeEventReducer {
    static func apply(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
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
            stopStreamingMessages(in: &state)
        case .runFailed:
            let message = payloadString("message", from: event.payload) ?? event.payload
            state.phase = .failed(message: message)
            state.errorMessage = message
            stopStreamingMessages(in: &state)
        default:
            break
        }
    }

    private static func appendUserMessage(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
        guard !state.messages.contains(where: { $0.id == event.id }) else {
            return
        }
        state.messages.append(AgentMessageViewState(
            id: event.id,
            role: .user,
            text: event.payload,
            isStreaming: false
        ))
    }

    private static func startAssistantMessage(_ event: RuntimeEventDTO, in state: inout AgentViewState) {
        let messageId = assistantMessageId(for: event, in: state)
        guard !state.messages.contains(where: { $0.id == messageId }) else {
            return
        }

        state.messages.append(AgentMessageViewState(
            id: messageId,
            role: .assistant,
            text: "",
            isStreaming: true
        ))
    }

    private static func appendAssistantDelta(_ event: RuntimeEventDTO, to state: inout AgentViewState) {
        let text = payloadString("text", from: event.payload) ?? event.payload
        let messageId = assistantMessageId(for: event, in: state)
        if let index = state.messages.firstIndex(where: { $0.id == messageId }) {
            state.messages[index].text += text
            state.messages[index].isStreaming = true
        } else {
            state.messages.append(AgentMessageViewState(
                id: messageId,
                role: .assistant,
                text: text,
                isStreaming: true
            ))
        }
    }

    private static func completeAssistantMessage(_ event: RuntimeEventDTO, in state: inout AgentViewState) {
        let messageId = assistantMessageId(for: event, in: state)
        let completedText = payloadString("text", from: event.payload) ?? event.payload

        if let index = state.messages.firstIndex(where: { $0.id == messageId }) {
            state.messages[index].text = completedText
            state.messages[index].isStreaming = false
        } else {
            state.messages.append(AgentMessageViewState(
                id: messageId,
                role: .assistant,
                text: completedText,
                isStreaming: false
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
            role: .tool,
            text: displayText,
            isStreaming: false
        ))
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

    private static func stopStreamingMessages(in state: inout AgentViewState) {
        for index in state.messages.indices where state.messages[index].isStreaming {
            state.messages[index].isStreaming = false
        }
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
