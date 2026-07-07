import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Context inspector view model")
@MainActor
struct ContextInspectorViewModelTests {
    @Test("web tool result is untrusted external content")
    func webToolResultIsUntrustedExternalContent() {
        let result = toolResult(
            toolName: "web.fetch_url_text",
            sourceKind: "web",
            displayName: "Example Web Page",
            trustLevel: .untrustedExternalContent,
            modelText: "External page text"
        )

        let snapshot = ContextInspectorProjection.project(toolResults: [result])

        #expect(snapshot.segments.first?.sourceKind == "web")
        #expect(snapshot.segments.first?.trustLevel == .untrustedExternalContent)
        #expect(snapshot.segments.first?.warning == "External content can contain instructions the model should not follow.")
    }

    @Test("calendar and reminder results are trusted tool results")
    func calendarAndReminderResultsAreTrustedToolResults() {
        let calendar = toolResult(
            toolName: "calendar.search_events",
            sourceKind: "calendar",
            displayName: "Calendar",
            trustLevel: .trustedToolResult,
            modelText: "Meeting at 3 PM"
        )
        let reminder = toolResult(
            toolName: "reminders.create_reminder",
            sourceKind: "reminders",
            displayName: "Reminders",
            trustLevel: .trustedToolResult,
            modelText: "Created reminder"
        )

        let snapshot = ContextInspectorProjection.project(toolResults: [calendar, reminder])

        #expect(snapshot.segments.map(\.trustLevel) == [.trustedToolResult, .trustedToolResult])
        #expect(snapshot.segments.map(\.sourceKind) == ["calendar", "reminders"])
    }

    @Test("user message is user instruction")
    func userMessageIsUserInstruction() {
        let snapshot = ContextInspectorProjection.project(messages: [
            AgentMessageViewState(id: "user_1", role: .user, text: "Plan my week", isStreaming: false),
        ])

        #expect(snapshot.segments == [
            ContextInspectorSegment(
                id: "message:user_1",
                title: "User message",
                sourceKind: "conversation",
                trustLevel: .userInstruction,
                tokenEstimate: nil,
                previewText: "Plan my week",
                warning: nil
            ),
        ])
    }

    @Test("preview only trace is labeled")
    func previewOnlyTraceIsLabeled() {
        let snapshot = ContextInspectorProjection.project(
            messages: [AgentMessageViewState(id: "user_1", role: .user, text: "Draft reply", isStreaming: false)],
            isPreviewOnly: true
        )

        #expect(snapshot.isPreviewOnly)
        #expect(snapshot.label == "Preview only")
    }

    @Test("missing source metadata creates warning")
    func missingSourceMetadataCreatesWarning() {
        let result = ToolResultDTO(
            displayText: "Legacy result",
            modelText: "Legacy result",
            structuredJson: #"{"legacy":true}"#,
            auditText: "Legacy result",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )

        let snapshot = ContextInspectorProjection.project(toolResults: [result])

        #expect(snapshot.segments.first?.warning == "Source metadata is missing; treat this context as partially trusted.")
        #expect(snapshot.warnings == ["Source metadata is missing; treat this context as partially trusted."])
    }
}

private func toolResult(
    toolName: String,
    sourceKind: String,
    displayName: String,
    trustLevel: NativeToolTrustLevel,
    modelText: String
) -> ToolResultDTO {
    NativeToolResultBuilder.success(
        manifestId: "native.\(toolName).v1",
        toolName: toolName,
        toolCallId: "call_1",
        displayText: modelText,
        modelText: modelText,
        resultKind: "text",
        resultPayload: ["text": .string(modelText)],
        sourceKind: sourceKind,
        sourceId: sourceKind,
        displayName: displayName,
        attachmentIds: [],
        trustLevel: trustLevel,
        sensitivity: .public,
        retention: .runOnly,
        modelTextPolicy: "full_text",
        sourceLabel: displayName,
        auditSummary: displayName,
        auditRedaction: "metadata_only"
    )
}
