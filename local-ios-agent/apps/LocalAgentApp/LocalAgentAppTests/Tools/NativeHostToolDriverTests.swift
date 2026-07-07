import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Native host tool driver")
struct NativeHostToolDriverTests {
    @Test
    func successfulNativeResultPreservesToolCallId() async throws {
        let toolkit = StubNativeToolkitClient(result: .success(toolName: "native.permission_status"))
        let driver = NativeHostToolDriver(toolkit: toolkit)

        let result = await driver.execute(
            toolRequest(toolName: "native.permission_status", toolCallId: "call_ok"),
            continuationIndex: 0
        )

        #expect(result?.isError == false)
        #expect(result?.structuredJson.contains(#""tool_call_id":"call_ok""#) == true)
    }

    @Test
    func duplicateToolCallReturnsNil() async throws {
        let toolkit = StubNativeToolkitClient(result: .success(toolName: "native.permission_status"))
        let driver = NativeHostToolDriver(toolkit: toolkit)
        let request = toolRequest(toolName: "native.permission_status", toolCallId: "call_dup")

        _ = await driver.execute(request, continuationIndex: 0)
        let second = await driver.execute(request, continuationIndex: 1)

        #expect(second == nil)
    }

    @Test
    func continuationLimitReturnsErrorEnvelope() async throws {
        let toolkit = StubNativeToolkitClient(result: .success(toolName: "native.permission_status"))
        let driver = NativeHostToolDriver(toolkit: toolkit, maxContinuations: 1)

        let result = await driver.execute(
            toolRequest(toolName: "native.permission_status"),
            continuationIndex: 1
        )

        #expect(result?.isError == true)
        #expect(result?.structuredJson.contains("continuation_limit_exceeded") == true)
    }

    @Test
    func schemasComeFromRegistrationSnapshot() async throws {
        let schema = ToolSchemaDTO(
            name: "native.permission_status",
            description: "Permission status",
            parametersJsonSchema: #"{"type":"object"}"#,
            riskLevel: .readOnly,
            metadataJson: "{}"
        )
        let toolkit = StubNativeToolkitClient(snapshot: NativeToolkitRegistrationSnapshot(
            schemas: [schema],
            toolNames: [schema.name]
        ))
        let driver = NativeHostToolDriver(toolkit: toolkit)

        let schemas = await driver.schemas()

        #expect(schemas == [schema])
    }

    private func toolRequest(
        toolName: String,
        toolCallId: String = "call_1"
    ) -> ToolExecutionRequestDTO {
        ToolExecutionRequestDTO(
            runId: "run_1",
            sessionId: "session_1",
            toolCallEntryId: "entry_1",
            toolCallId: toolCallId,
            toolName: toolName,
            argumentsJson: "{}"
        )
    }
}

private actor StubNativeToolkitClient: NativeToolkitClientProtocol {
    enum ResultShape {
        case success(toolName: String)
        case error(toolName: String)
    }

    private let snapshot: NativeToolkitRegistrationSnapshot
    private let result: ResultShape

    init(
        snapshot: NativeToolkitRegistrationSnapshot = NativeToolkitRegistrationSnapshot(schemas: [], toolNames: []),
        result: ResultShape = .success(toolName: "native.permission_status")
    ) {
        self.snapshot = snapshot
        self.result = result
    }

    func registrationSnapshot() async -> NativeToolkitRegistrationSnapshot {
        snapshot
    }

    func execute(_ request: ToolExecutionRequestDTO) async -> ToolResultDTO {
        switch result {
        case .success(let toolName):
            NativeToolResultBuilder.success(
                manifestId: "native.\(toolName).v1",
                toolName: toolName,
                toolCallId: request.toolCallId,
                displayText: "ok",
                modelText: "ok",
                resultKind: "stub",
                resultPayload: [:],
                sourceKind: "tool",
                sourceId: toolName,
                displayName: toolName,
                attachmentIds: [],
                trustLevel: .trustedToolResult,
                sensitivity: .public,
                retention: .runOnly,
                modelTextPolicy: "tool_status",
                sourceLabel: "Tool",
                auditSummary: "ok",
                auditRedaction: "metadata_only"
            )
        case .error(let toolName):
            NativeToolResultBuilder.error(
                manifestId: "native.\(toolName).v1",
                toolName: toolName,
                toolCallId: request.toolCallId,
                code: "stub_error",
                displayText: "error",
                auditSummary: "error"
            )
        }
    }
}
