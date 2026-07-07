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

        #expect(result.isError == false)
        #expect(result.modelText == "executed debug.echo")
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

    private func envelopePayload(from result: ToolResultDTO) throws -> [String: Any] {
        let data = try #require(result.structuredJson.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
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
        return ToolResultDTO(
            displayText: "executed \(schema.name)",
            modelText: "executed \(schema.name)",
            structuredJson: #"{"ok":true}"#,
            auditText: "executed \(schema.name)",
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
