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

        #expect(result.isError)
        #expect(result.modelText.contains("Unknown native tool `missing.tool`"))
        #expect(result.structuredJson == #"{"error":"unknown_tool","tool_name":"missing.tool"}"#)
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

        #expect(result.isError)
        #expect(result.modelText.contains("Invalid arguments for native tool `debug.echo`"))
        #expect(result.structuredJson == #"{"error":"invalid_arguments","tool_name":"debug.echo"}"#)
        #expect(await recorder.arguments == [])
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
