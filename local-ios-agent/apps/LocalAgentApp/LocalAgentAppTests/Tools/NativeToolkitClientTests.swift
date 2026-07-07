import Foundation
import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Native toolkit client")
struct NativeToolkitClientTests {
    @Test
    func registrationSnapshotExportsManifestBackedSchemasSortedByName() async throws {
        let catalog = try NativeToolCatalog(tools: [
            ClientStubTool(name: "web.fetch_url_text", manifestRiskLevel: .confirm),
            ClientStubTool(name: "debug.echo", manifestRiskLevel: nil),
            ClientStubTool(name: "native.permission_status", manifestRiskLevel: .readOnly),
            ClientStubTool(name: "native.list_tools", manifestRiskLevel: .readOnly),
        ])
        let client = NativeToolkitClient(catalog: catalog)

        let snapshot = await client.registrationSnapshot()

        #expect(snapshot.schemas.map(\.name) == [
            "native.list_tools",
            "native.permission_status",
            "web.fetch_url_text",
        ])
        #expect(snapshot.toolNames == snapshot.schemas.map(\.name))
        #expect(snapshot.schemas.allSatisfy { $0.metadataJson != nil })
        #expect(snapshot.schemas.contains { $0.name == "debug.echo" } == false)
    }

    @Test
    func executeRejectsManifestlessToolBeforeCallingRawTool() async throws {
        let calls = ClientCallBox()
        let catalog = try NativeToolCatalog(tools: [
            ClientStubTool(name: "debug.unmanifested", manifestRiskLevel: nil, calls: calls),
        ])
        let client = NativeToolkitClient(catalog: catalog)

        let result = await client.execute(toolRequest(toolName: "debug.unmanifested"))

        #expect(result.isError == true)
        #expect(result.structuredJson.contains("native_tool_unavailable"))
        #expect(await calls.count == 0)
    }

    @Test
    func executePatchesToolCallIdForManifestBackedTool() async throws {
        let catalog = try NativeToolCatalog(tools: [
            ClientStubTool(name: "native.permission_status", manifestRiskLevel: .readOnly),
        ])
        let client = NativeToolkitClient(catalog: catalog)

        let result = await client.execute(toolRequest(toolName: "native.permission_status", toolCallId: "call_real"))

        #expect(result.isError == false)
        #expect(result.structuredJson.contains(#""tool_call_id":"call_real""#))
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

private actor ClientCallBox {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private struct ClientStubTool: NativeTool {
    var schema: NativeToolSchema
    private let calls: ClientCallBox?

    init(name: String, manifestRiskLevel: NativeToolRiskLevel?, calls: ClientCallBox? = nil) {
        self.calls = calls
        let manifest = manifestRiskLevel.map { risk in
            NativeToolManifest(
                manifestId: "native.\(name).v1",
                capabilityId: name,
                title: name,
                description: "Client stub",
                mode: .background,
                permissionScope: nil,
                requiredPrivacyKeys: [],
                requiresForegroundUI: false,
                minimumOS: "iOS 17.0",
                regionPolicy: "available_with_service_fallback",
                fallback: NativeToolFallback(kind: .none, message: ""),
                riskLevel: risk,
                approvalPolicy: .never,
                trustLevel: .trustedToolResult,
                retention: .runOnly,
                audit: NativeToolAudit(label: name, resultSummaryPolicy: .metadataOnly)
            )
        }
        self.schema = NativeToolSchema(
            name: name,
            description: "Client stub",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
            availability: .available,
            manifest: manifest
        )
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        await calls?.increment()
        return NativeToolResultBuilder.success(
            manifestId: schema.manifest?.manifestId ?? "native.stub.v1",
            toolName: schema.name,
            toolCallId: "unknown",
            displayText: "ok",
            modelText: "ok",
            resultKind: "stub",
            resultPayload: [:],
            sourceKind: "tool",
            sourceId: schema.name,
            displayName: schema.name,
            attachmentIds: [],
            trustLevel: .trustedToolResult,
            sensitivity: .public,
            retention: .runOnly,
            modelTextPolicy: "tool_status",
            sourceLabel: "Tool",
            auditSummary: "ok",
            auditRedaction: "metadata_only"
        )
    }
}
