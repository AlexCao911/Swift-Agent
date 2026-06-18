import Foundation
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Native tool schema export")
struct NativeToolSchemaExportTests {
    @Test
    func exportsAvailableNativeSchemasInBridgeDTOShape() throws {
        let parameters = #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        let catalog = try NativeToolCatalog(tools: [
            ExportStubTool(
                schema: NativeToolSchema(
                    name: "calendar.search_events",
                    description: "Search calendar events",
                    inputSchema: JSONSchemaDTO(jsonString: parameters),
                    riskLevel: .confirm,
                    permissionScope: NativePermissionScope("calendar.events"),
                    availability: .available
                )
            ),
            ExportStubTool(
                schema: NativeToolSchema(
                    name: "calendar.disabled",
                    description: "Unavailable",
                    inputSchema: .object(),
                    riskLevel: .readOnly,
                    permissionScope: nil,
                    availability: .unavailable(reason: "disabled")
                )
            ),
        ])

        let exported = NativeToolSchemaExport.exportSchemas(from: catalog)

        #expect(exported.map(\.name) == ["calendar.search_events"])
        #expect(exported[0].description == "Search calendar events")
        #expect(exported[0].parametersJsonSchema == parameters)
        #expect(exported[0].riskLevel == .confirm)
        #expect(exported[0].metadataJson == #"{"native_permission_scope":"calendar.events"}"#)

        let encoded = try JSONEncoder().encode(exported[0])
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?["name"] as? String == "calendar.search_events")
        #expect(object?["description"] as? String == "Search calendar events")
        #expect(object?["parameters_json_schema"] as? String == parameters)
        #expect(object?["risk_level"] as? String == "confirm")
        #expect(object?["metadata_json"] as? String == #"{"native_permission_scope":"calendar.events"}"#)
    }

    @Test
    func mapsAllNativeRiskLevelsToBridgeRiskLevels() throws {
        #expect(NativeToolSchemaExport.bridgeRiskLevel(for: .readOnly) == .readOnly)
        #expect(NativeToolSchemaExport.bridgeRiskLevel(for: .confirm) == .confirm)
        #expect(NativeToolSchemaExport.bridgeRiskLevel(for: .destructive) == .destructive)
    }
}

private struct ExportStubTool: NativeTool {
    var schema: NativeToolSchema

    func execute(argumentsJson: String) async -> ToolResultDTO {
        ToolResultDTO(
            displayText: "ok",
            modelText: "ok",
            structuredJson: "{}",
            auditText: "ok",
            sensitivity: .public,
            retention: .runOnly,
            isError: false
        )
    }
}
