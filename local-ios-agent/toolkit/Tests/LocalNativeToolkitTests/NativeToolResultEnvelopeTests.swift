import Foundation
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Native tool result envelope")
struct NativeToolResultEnvelopeTests {
    @Test
    func successEnvelopeCarriesTrustAndProvenance() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.web.fetch_url_text.v1",
            toolName: "web.fetch_url_text",
            toolCallId: "call_1",
            displayText: "Fetched example.com",
            modelText: "External content from example.com:\nhello",
            resultKind: "web_text",
            resultPayload: ["text_excerpt": .string("hello")],
            sourceKind: "web",
            sourceId: "https://example.com",
            displayName: "example.com",
            attachmentIds: [],
            trustLevel: .untrustedExternalContent,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "summarize_or_quote_only",
            sourceLabel: "Web",
            auditSummary: "Fetched text from example.com",
            auditRedaction: "excerpt_only"
        )

        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let provenance = try #require(object["provenance"] as? [String: Any])
        let contextPolicy = try #require(object["context_policy"] as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["manifest_id"] as? String == "native.web.fetch_url_text.v1")
        #expect(provenance["trust_level"] as? String == "untrusted_external_content")
        #expect(provenance["retention"] as? String == "run_only")
        #expect(contextPolicy["model_text_policy"] as? String == "summarize_or_quote_only")
        #expect(result.sensitivity == .public)
        #expect(result.retention == .runOnly)
        #expect(result.isError == false)
    }

    @Test
    func envelopeSupportsNestedArraysAndObjects() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.native.list_tools.v1",
            toolName: "native.list_tools",
            toolCallId: "call_1",
            displayText: "2 tools available",
            modelText: "Available tools: calendar.search_events, reminders.create_reminder",
            resultKind: "native_tool_status",
            resultPayload: [
                "tools": .array([
                    .object(["name": .string("calendar.search_events")]),
                    .object(["name": .string("reminders.create_reminder")]),
                ]),
                "permissions": .array([
                    .object(["scope": .string("calendar.events.read_full")]),
                ]),
            ],
            sourceKind: "tool",
            sourceId: "native.list_tools",
            displayName: "List Tools",
            attachmentIds: [],
            trustLevel: .trustedToolResult,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "tool_status",
            sourceLabel: "Tool",
            auditSummary: "Listed tools",
            auditRedaction: "metadata_only"
        )

        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        let tools = try #require(payload["tools"] as? [[String: Any]])

        #expect(tools.map { $0["name"] as? String } == [
            "calendar.search_events",
            "reminders.create_reminder",
        ])
    }

    @Test
    func errorEnvelopeUsesSafePolicyFields() throws {
        let result = NativeToolResultBuilder.error(
            manifestId: "native.executor.v1",
            toolName: "missing.tool",
            toolCallId: "unknown",
            code: "unknown_tool",
            displayText: "Unknown native tool",
            auditSummary: "Unknown native tool: missing.tool"
        )

        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resultObject = try #require(object["result"] as? [String: Any])

        #expect(resultObject["code"] as? String == "unknown_tool")
        #expect(result.isError == true)
        #expect(result.sensitivity == .public)
        #expect(result.retention == .runOnly)
    }

    @Test
    func validatorRejectsErrorFlagMismatch() throws {
        let result = NativeToolResultBuilder.error(
            manifestId: "native.executor.v1",
            toolName: "native.executor",
            toolCallId: "call_1",
            code: "tool_executor_error",
            displayText: "Tool failed",
            auditSummary: "Tool failed"
        )
        let mismatched = ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: result.sensitivity,
            retention: result.retention,
            isError: false
        )

        #expect(throws: NativeToolResultEnvelopeValidationError.self) {
            try NativeToolResultEnvelopeValidator.validate(mismatched)
        }
    }

    @Test
    func validatorKeepsConservativeSensitivity() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.files.read_attachment.v1",
            toolName: "files.read_attachment",
            toolCallId: "call_1",
            displayText: "Read file",
            modelText: "File text",
            resultKind: "attachment_text",
            resultPayload: ["attachment_id": .string("att_1")],
            sourceKind: "attachment",
            sourceId: "att_1",
            displayName: "notes.txt",
            attachmentIds: ["att_1"],
            trustLevel: .untrustedExternalContent,
            sensitivity: .private,
            retention: .runOnly,
            modelTextPolicy: "summarize_or_quote_only",
            sourceLabel: "File",
            auditSummary: "Read attachment",
            auditRedaction: "metadata_only"
        )
        let weakened = ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )

        let validated = try NativeToolResultEnvelopeValidator.validate(weakened)

        #expect(validated.sensitivity == .private)
        #expect(validated.retention == .runOnly)
    }

    @Test
    func validatorRejectsRetentionMismatch() throws {
        let result = NativeToolResultBuilder.success(
            manifestId: "native.files.read_attachment.v1",
            toolName: "files.read_attachment",
            toolCallId: "call_1",
            displayText: "Read file",
            modelText: "File text",
            resultKind: "attachment_text",
            resultPayload: ["attachment_id": .string("att_1")],
            sourceKind: "attachment",
            sourceId: "att_1",
            displayName: "notes.txt",
            attachmentIds: ["att_1"],
            trustLevel: .untrustedExternalContent,
            sensitivity: .private,
            retention: .runOnly,
            modelTextPolicy: "summarize_or_quote_only",
            sourceLabel: "File",
            auditSummary: "Read attachment",
            auditRedaction: "metadata_only"
        )
        let mismatched = ToolResultDTO(
            displayText: result.displayText,
            modelText: result.modelText,
            structuredJson: result.structuredJson,
            auditText: result.auditText,
            sensitivity: result.sensitivity,
            retention: .session,
            isError: false
        )

        #expect(throws: NativeToolResultEnvelopeValidationError.self) {
            try NativeToolResultEnvelopeValidator.validate(mismatched)
        }
    }
}
