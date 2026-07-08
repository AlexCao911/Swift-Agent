import Foundation
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

    @Test("sequenced events are applied once")
    func sequencedEventsApplyOnce() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(
                id: "assistant_started",
                kind: .assistantMessageStarted,
                payload: #"{"message_id":"assistant_1"}"#,
                sequence: 1
            ),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "delta_1",
                kind: .assistantTextDelta,
                payload: #"{"message_id":"assistant_1","text":"hello"}"#,
                sequence: 2
            ),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "delta_1",
                kind: .assistantTextDelta,
                payload: #"{"message_id":"assistant_1","text":"hello"}"#,
                sequence: 2
            ),
            to: &state
        )

        #expect(state.messages.map(\.text) == ["hello"])
        #expect(state.lastAppliedRuntimeSequence == 2)
    }

    @Test("execution replay sequence is scoped per run")
    func executionReplaySequenceIsScopedPerRun() {
        var state = AgentViewState(lastAppliedRuntimeSequence: 42)

        RuntimeEventReducer.apply(
            event(
                id: "run_2.1",
                kind: .assistantMessageCompleted,
                payload: #"{"message_id":"assistant_run_2","text":"done"}"#,
                runId: "run_2",
                sequence: 1,
                sessionId: ""
            ),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "run_2.1",
                kind: .assistantMessageCompleted,
                payload: #"{"message_id":"assistant_run_2","text":"duplicate"}"#,
                runId: "run_2",
                sequence: 1,
                sessionId: ""
            ),
            to: &state
        )

        #expect(state.messages.map(\.text) == ["done"])
        #expect(state.lastAppliedRuntimeSequence == 42)
    }

    @Test("pending interaction events feed transient run cards")
    func pendingInteractionEventsFeedTransientRunCards() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(
                id: "pending_1",
                kind: .runSuspended,
                payload: #"{"type":"pending_user_interaction","interaction_id":"pending_1","tool_name":"photos.pick_images","title":"Choose photos"}"#
            ),
            to: &state
        )

        #expect(state.transientRunEvents.map(\.id) == ["pending_1"])
        #expect(RunInlineCardProjection.project(state: state) == [
            .pendingInteraction(PendingInteractionCardState(
                id: "pending_1",
                toolName: "photos.pick_images",
                title: "Choose photos"
            )),
        ])
    }

    @Test("terminal events clear transient run cards")
    func terminalEventsClearTransientRunCards() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(
                id: "pending_1",
                kind: .runSuspended,
                payload: #"{"type":"pending_user_interaction","interaction_id":"pending_1","tool_name":"photos.pick_images","title":"Choose photos"}"#
            ),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "completed",
                kind: .assistantMessageCompleted,
                payload: #"{"message_id":"assistant_1","text":"done"}"#
            ),
            to: &state
        )

        #expect(state.transientRunEvents.isEmpty)
        #expect(RunInlineCardProjection.project(state: state).isEmpty)
    }

    @Test("assistant reasoning tags are projected as reasoning parts")
    func assistantReasoningProjectsAsParts() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"<think>hidden"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_2", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"</think>visible"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"<think>hidden</think>visible"}"#),
            to: &state
        )

        #expect(state.messages.count == 1)
        #expect(state.messages[0].parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "visible")),
        ])
        #expect(state.messages[0].text == "hiddenvisible")
        #expect(!state.messages[0].isStreaming)
    }

    @Test("runtime messages preserve metadata and structured parts")
    func runtimeMessagesPreserveMetadataAndStructuredParts() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(id: "user_1", kind: .userMessage, payload: "hello", parentId: "parent_user"),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "assistant_started",
                kind: .assistantMessageStarted,
                payload: #"{"message_id":"assistant_1"}"#,
                parentId: "parent_assistant"
            ),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"hi"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "completed",
                kind: .assistantMessageCompleted,
                payload: #"{"message_id":"assistant_1","text":"hi"}"#,
                parentId: "ignored_parent"
            ),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(
                id: "tool_result",
                kind: .toolResultMessage,
                payload: #"{"display_text":"Echo: hello"}"#,
                parentId: "parent_tool"
            ),
            to: &state
        )

        #expect(state.messages.count == 3)
        #expect(state.messages[0].sessionId == "session_1")
        #expect(state.messages[0].parentId == "parent_user")
        #expect(state.messages[0].parts == [
            .text(TextPartViewState(id: "user_1_text_0", text: "hello")),
        ])
        #expect(state.messages[1].sessionId == "session_1")
        #expect(state.messages[1].parentId == "parent_assistant")
        #expect(state.messages[1].branchLeafId == "completed")
        #expect(state.messages[1].parts == [
            .text(TextPartViewState(id: "text_0", text: "hi")),
        ])
        #expect(state.messages[2].sessionId == "session_1")
        #expect(state.messages[2].parentId == "parent_tool")
        #expect(state.messages[2].branchLeafId == "tool_result")
        #expect(state.messages[2].parts == [
            .tool(ToolPartViewState(id: "tool_result", displayText: "Echo: hello")),
        ])
    }

    @Test("assistant completed event becomes branch leaf id")
    func assistantCompletedEventBecomesBranchLeafId() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "completed_leaf", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"done"}"#),
            to: &state
        )

        #expect(state.messages.map(\.id) == ["assistant_1"])
        #expect(state.messages[0].branchLeafId == "completed_leaf")
    }

    @Test("user blob refs restore visible text and attachments")
    func userBlobRefsRestoreVisibleTextAndAttachments() {
        var state = AgentViewState()
        let blobRefs = RuntimeBlobRefCodec.encodeUserMessage(
            text: "hello",
            attachments: [
                AttachmentDraftViewState(
                    id: "link_1",
                    kind: .link,
                    displayName: "example.com",
                    localPath: nil,
                    urlString: "https://example.com",
                    mimeType: nil,
                    byteCount: nil
                ),
            ]
        )

        RuntimeEventReducer.apply(
            event(
                id: "user_1",
                kind: .userMessage,
                payload: "hello\nLink: https://example.com",
                blobRefs: blobRefs
            ),
            to: &state
        )

        #expect(state.messages.count == 1)
        #expect(state.messages[0].text == "hello")
        #expect(state.messages[0].attachments == [
            AttachmentViewState(
                id: "link_1",
                kind: .link,
                displayName: "example.com",
                localPath: nil,
                urlString: "https://example.com",
                mimeType: nil,
                byteCount: nil
            ),
        ])
    }

    @Test("user blob refs restore visible file attachments")
    func userBlobRefsRestoreVisibleFileAttachments() {
        var state = AgentViewState()
        let blobRefs = RuntimeBlobRefCodec.encodeUserMessage(
            text: "summarize",
            attachments: [
                AttachmentDraftViewState(
                    id: "file_1",
                    kind: .file,
                    displayName: "notes.txt",
                    localPath: "/tmp/notes.txt",
                    urlString: nil,
                    mimeType: "text/plain",
                    byteCount: 9,
                    textContent: "Trip plan"
                ),
            ]
        )

        RuntimeEventReducer.apply(
            event(
                id: "user_1",
                kind: .userMessage,
                payload: "summarize\nFile attached: notes.txt\nFile contents:\nTrip plan",
                blobRefs: blobRefs
            ),
            to: &state
        )

        #expect(state.messages.count == 1)
        #expect(state.messages[0].text == "summarize")
        #expect(state.messages[0].attachments == [
            AttachmentViewState(
                id: "file_1",
                kind: .file,
                displayName: "notes.txt",
                localPath: "/tmp/notes.txt",
                urlString: nil,
                mimeType: "text/plain",
                byteCount: 9,
                textContent: "Trip plan"
            ),
        ])
    }

    @Test("user blob refs restore image preview data for history")
    func userBlobRefsRestoreImagePreviewDataForHistory() {
        var state = AgentViewState()
        let previewDataBase64 = "iVBORw0KGgo="
        let blobRefs = RuntimeBlobRefCodec.encodeUserMessage(
            text: "what is this",
            attachments: [
                AttachmentDraftViewState(
                    id: "image_1",
                    kind: .image,
                    displayName: "photo.jpeg",
                    localPath: "/missing/photo.jpeg",
                    urlString: nil,
                    mimeType: "image/jpeg",
                    byteCount: 42,
                    imageWidth: 2,
                    imageHeight: 3,
                    rgbDataBase64: "AQIDBAUG",
                    previewDataBase64: previewDataBase64
                ),
            ]
        )

        RuntimeEventReducer.apply(
            event(
                id: "user_1",
                kind: .userMessage,
                payload: "what is this\nImage attached: photo.jpeg",
                blobRefs: blobRefs
            ),
            to: &state
        )

        #expect(state.messages.count == 1)
        #expect(state.messages[0].text == "what is this")
        #expect(state.messages[0].attachments[0].previewDataBase64 == previewDataBase64)
        #expect(state.messages[0].attachments[0].previewImageData == Data(base64Encoded: previewDataBase64))
    }

    @Test("assistant delta fallback preserves split reasoning source")
    func assistantDeltaFallbackPreservesSplitReasoningSource() {
        var state = AgentViewState()

        RuntimeEventReducer.apply(
            event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"<think>hidden"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_2", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"</think>visible"}"#),
            to: &state
        )

        #expect(state.messages.count == 1)
        #expect(state.messages[0].parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "hidden", isCollapsed: true, isStreaming: false)),
            .text(TextPartViewState(id: "text_1", text: "visible")),
        ])
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

        #expect(state.messages.map(\.id) == ["user_1", "assistant_started"])
        #expect(state.messages.map(\.role) == [.user, .assistant])
        #expect(state.messages.map(\.text) == ["hello", "Mock response to: hello"])
        #expect(!state.messages[0].isStreaming)
        #expect(!state.messages[1].isStreaming)
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

        #expect(state.messages.count == 1)
        #expect(state.messages[0].id == "tool_result")
        #expect(state.messages[0].role == .tool)
        #expect(state.messages[0].text == "Echo: hello")
        #expect(!state.messages[0].isStreaming)
        #expect(state.phase == .ready)
    }

    @Test("run cancellation preserves partial assistant output")
    func runCancellationPreservesPartialAssistantOutput() {
        var state = AgentViewState(phase: .running(runId: "run_1"))

        RuntimeEventReducer.apply(
            event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"<think>partial"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(event(id: "cancelled", kind: .runCancelled, payload: "cancelled"), to: &state)

        #expect(state.phase == .ready)
        #expect(state.lastTerminalReason == .cancelled)
        #expect(state.messages[0].streaming == .cancelled)
        #expect(state.messages[0].text == "partial")
        #expect(state.messages[0].parts == [
            .reasoning(ReasoningPartViewState(id: "reasoning_0", text: "partial", isCollapsed: true, isStreaming: false)),
        ])
    }

    @Test("run failure preserves partial assistant output")
    func runFailurePreservesPartialAssistantOutput() {
        var state = AgentViewState(phase: .running(runId: "run_1"))

        RuntimeEventReducer.apply(
            event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(
            event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"partial"}"#),
            to: &state
        )
        RuntimeEventReducer.apply(event(id: "failed", kind: .runFailed, payload: #"{"message":"model stopped"}"#), to: &state)

        #expect(state.phase == .failed(message: "model stopped"))
        #expect(state.errorMessage == "model stopped")
        #expect(state.lastTerminalReason == .failed("model stopped"))
        #expect(state.messages[0].streaming == .failed("model stopped"))
        #expect(state.messages[0].text == "partial")
    }

    private func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String,
        parentId: String? = nil,
        runId: String? = "run_1",
        blobRefs: [String] = [],
        sequence: UInt64 = 0,
        sessionId: String = "session_1"
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: sessionId,
            parentId: parentId,
            runId: runId,
            sequence: sequence,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: blobRefs
        )
    }
}
