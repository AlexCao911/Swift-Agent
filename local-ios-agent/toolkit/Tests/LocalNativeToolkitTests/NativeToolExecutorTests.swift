import Foundation
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Native tool executor")
struct NativeToolExecutorTests {
    @Test
    func executorDispatchesRequestsByToolName() async throws {
        let recorder = ToolCallRecorder()
        let catalog = try NativeToolCatalog(tools: [
            RecordingTool(name: "debug.echo", recorder: recorder),
        ])
        let executor = NativeToolExecutor(catalog: catalog)

        let result = await executor.execute(request(
            toolName: "debug.echo",
            argumentsJson: #"{"text":"hello"}"#
        ))
        let envelope = try envelopeObject(from: result)

        #expect(result.isError == false)
        #expect(result.modelText == "executed debug.echo")
        #expect(envelope["tool_call_id"] as? String == "call_1")
        #expect(await recorder.arguments == [#"{"text":"hello"}"#])
    }

    @Test
    func executorReturnsModelVisibleErrorForUnknownTool() async throws {
        let executor = NativeToolExecutor(catalog: try NativeToolCatalog(tools: []))

        let result = await executor.execute(request(toolName: "missing.tool"))
        let payload = try envelopePayload(from: result)

        #expect(result.isError)
        #expect(result.modelText.contains("Tool error `unknown_tool`"))
        #expect(payload["kind"] as? String == "error")
        #expect(payload["code"] as? String == "unknown_tool")
    }

    @Test
    func executorReturnsModelVisibleErrorForInvalidArguments() async throws {
        let recorder = ToolCallRecorder()
        let catalog = try NativeToolCatalog(tools: [
            RecordingTool(name: "debug.echo", recorder: recorder),
        ])
        let executor = NativeToolExecutor(catalog: catalog)

        let result = await executor.execute(request(
            toolName: "debug.echo",
            argumentsJson: #"["not","object"]"#
        ))
        let payload = try envelopePayload(from: result)

        #expect(result.isError)
        #expect(result.modelText.contains("Tool error `invalid_arguments`"))
        #expect(payload["kind"] as? String == "error")
        #expect(payload["code"] as? String == "invalid_arguments")
        #expect(await recorder.arguments == [])
    }

    @Test
    func executorRejectsToolResultWithoutEnvelope() async throws {
        let catalog = try NativeToolCatalog(tools: [
            RawResultTool(name: "debug.raw"),
        ])
        let executor = NativeToolExecutor(catalog: catalog)

        let result = await executor.execute(request(toolName: "debug.raw"))
        let payload = try envelopePayload(from: result)
        let envelope = try envelopeObject(from: result)

        #expect(result.isError)
        #expect(payload["code"] as? String == "invalid_tool_result_envelope")
        #expect(envelope["tool_call_id"] as? String == "call_1")
    }

    private func envelopePayload(from result: ToolResultDTO) throws -> [String: Any] {
        let object = try envelopeObject(from: result)
        return try #require(object["result"] as? [String: Any])
    }

    private func envelopeObject(from result: ToolResultDTO) throws -> [String: Any] {
        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
    }

    private func request(
        toolName: String,
        argumentsJson: String = "{}"
    ) -> ToolExecutionRequestDTO {
        ToolExecutionRequestDTO(
            runId: "run_1",
            sessionId: "session_1",
            toolCallEntryId: "entry_1",
            toolCallId: "call_1",
            toolName: toolName,
            argumentsJson: argumentsJson
        )
    }
}

private struct RecordingTool: NativeTool {
    var schema: NativeToolSchema
    let recorder: ToolCallRecorder

    init(name: String, recorder: ToolCallRecorder) {
        self.schema = NativeToolSchema(
            name: name,
            description: "Records arguments",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available
        )
        self.recorder = recorder
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        await recorder.record(argumentsJson)
        return NativeToolResultBuilder.success(
            manifestId: "native.debug.echo.v1",
            toolName: schema.name,
            toolCallId: "unknown",
            displayText: "executed \(schema.name)",
            modelText: "executed \(schema.name)",
            resultKind: "debug_echo",
            resultPayload: ["ok": .bool(true)],
            sourceKind: "tool",
            sourceId: schema.name,
            displayName: "Debug Echo",
            attachmentIds: [],
            trustLevel: .trustedToolResult,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "tool_status",
            sourceLabel: "Tool",
            auditSummary: "executed \(schema.name)",
            auditRedaction: "metadata_only"
        )
    }
}

private struct RawResultTool: NativeTool {
    var schema: NativeToolSchema

    init(name: String) {
        self.schema = NativeToolSchema(
            name: name,
            description: "Returns raw JSON",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available
        )
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        ToolResultDTO(
            displayText: "raw",
            modelText: "raw",
            structuredJson: #"{"ok":true}"#,
            auditText: "raw",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }
}

private actor ToolCallRecorder {
    private var recordedArguments: [String] = []

    var arguments: [String] {
        recordedArguments
    }

    func record(_ argumentsJson: String) {
        recordedArguments.append(argumentsJson)
    }
}
