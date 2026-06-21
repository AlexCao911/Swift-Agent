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
            sessionId: event.sessionId,
            parentId: event.parentId,
            role: .user,
            parts: [.text(TextPartViewState(id: "\(event.id)_text_0", text: event.payload))],
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
            state.messages.append(AgentMessageViewState(
                id: messageId,
                sessionId: event.sessionId,
                parentId: event.parentId,
                role: .assistant,
                parts: parsedAssistantParts(from: text, isFinal: false),
                streaming: .streaming
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
                sessionId: event.sessionId,
                parentId: event.parentId,
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
