import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Runtime event reducer")
struct RuntimeEventReducerTests {
    @Test("assistant JSON deltas append to streaming message")
    func assistantDeltasAppendToStreamingMessage() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"hello"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_2", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":" world"}"#),
            to: &state
        )

        #expect(state.messages.count == 1)
        #expect(state.messages[0].role == .assistant)
        #expect(state.messages[0].text == "hello world")
        #expect(state.messages[0].isStreaming)
    }

    @Test("rust plain-text events project user and assistant messages")
    func rustPlainTextEventsProjectConversation() {
        var state = AgentViewState(phase: .running(runId: "run_1"))

        RuntimeEventReducer.apply(event(id: "user_1", kind: .userMessage, payload: "hello"), to: &state)
        RuntimeEventReducer.apply(event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"), to: &state)
        RuntimeEventReducer.apply(event(id: "delta_1", kind: .assistantTextDelta, payload: "Mock "), to: &state)
        RuntimeEventReducer.apply(event(id: "delta_2", kind: .assistantTextDelta, payload: "response to: hello"), to: &state)
        RuntimeEventReducer.apply(
            event(id: "completed", kind: .assistantMessageCompleted, payload: "Mock response to: hello"),
            to: &state
        )

        #expect(state.messages == [
            AgentMessageViewState(id: "user_1", role: .user, text: "hello", isStreaming: false),
            AgentMessageViewState(
                id: "assistant_started",
                role: .assistant,
                text: "Mock response to: hello",
                isStreaming: false
            ),
        ])
    }

    @Test("tool result and terminal events update visible state")
    func terminalEventsUpdateVisibleState() {
        var state = AgentViewState(phase: .running(runId: "run_1"))

        RuntimeEventReducer.apply(
            event(
                id: "tool_result",
                kind: .toolResultMessage,
                payload: #"{"type":"tool_result","display_text":"Echo: hello","model_text":"debug.echo: hello","structured_json":"{}","audit_text":"audit","sensitivity":"public","retention":"run_only","is_error":false}"#
            ),
            to: &state
        )
        RuntimeEventReducer.apply(event(id: "cancelled", kind: .runCancelled, payload: "cancelled"), to: &state)

        #expect(state.messages == [
            AgentMessageViewState(id: "tool_result", role: .tool, text: "Echo: hello", isStreaming: false),
        ])
        #expect(state.phase == .ready)
    }

    private func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String,
        runId: String? = "run_1"
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}
