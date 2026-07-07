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
        #expect(exported[0].metadataJson == nil)

        let encoded = try JSONEncoder().encode(exported[0])
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?["name"] as? String == "calendar.search_events")
        #expect(object?["description"] as? String == "Search calendar events")
        #expect(object?["parameters_json_schema"] as? String == parameters)
        #expect(object?["risk_level"] as? String == "confirm")
        #expect(object?["metadata_json"] == nil)
    }

    @Test
    func mapsAllNativeRiskLevelsToBridgeRiskLevels() throws {
        #expect(NativeToolSchemaExport.bridgeRiskLevel(for: .readOnly) == .readOnly)
        #expect(NativeToolSchemaExport.bridgeRiskLevel(for: .confirm) == .confirm)
        #expect(NativeToolSchemaExport.bridgeRiskLevel(for: .destructive) == .destructive)
    }

    @Test
    func exportsManifestMetadataV1() throws {
        let manifest = NativeToolManifest(
            manifestId: "native.calendar.search_events.v1",
            capabilityId: "calendar.events.search",
            title: "Search Calendar",
            description: "Search calendar events",
            mode: .background,
            permissionScope: NativePermissionScope("calendar.events.read_full"),
            requiredPrivacyKeys: ["NSCalendarsFullAccessUsageDescription"],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .openSettings, message: "Calendar access is required."),
            riskLevel: .readOnly,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Calendar Search", resultSummaryPolicy: .metadataOnly)
        )
        let catalog = try NativeToolCatalog(tools: [
            ExportStubTool(
                schema: NativeToolSchema(
                    name: "calendar.search_events",
                    description: "Search calendar events",
                    inputSchema: .object(properties: ["query": .string()], required: ["query"]),
                    riskLevel: .readOnly,
                    permissionScope: NativePermissionScope("calendar.events.read_full"),
                    availability: .available,
                    manifest: manifest
                )
            ),
        ])

        let exported = NativeToolSchemaExport.exportSchemas(from: catalog)
        #expect(exported.count == 1)
        let metadata = try #require(exported[0].metadataJson)
        let data = try #require(metadata.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["manifest_id"] as? String == "native.calendar.search_events.v1")
        #expect(object["capability_id"] as? String == "calendar.events.search")
        #expect(object["tool_mode"] as? String == "background")
        #expect(object["permission_scope"] as? String == "calendar.events.read_full")
        #expect(object["approval_policy"] as? String == "per_call")
        #expect(object["context_trust_level"] as? String == "trusted_tool_result")

        let availability = try #require(object["availability"] as? [String: Any])
        let audit = try #require(object["audit"] as? [String: Any])
        #expect(availability["os_minimum"] as? String == "iOS 17.0")
        #expect(availability["region_policy"] as? String == "available_with_service_fallback")
        #expect(audit["result_summary_policy"] as? String == "metadata_only")
        #expect(audit["resultSummaryPolicy"] == nil)
    }

    @Test
    func missingManifestDoesNotSynthesizeProductMetadata() throws {
        let catalog = try NativeToolCatalog(tools: [
            ExportStubTool(
                schema: NativeToolSchema(
                    name: "legacy.tool",
                    description: "Legacy tool",
                    inputSchema: .object(properties: [:], required: []),
                    riskLevel: .readOnly,
                    permissionScope: nil,
                    availability: .available
                )
            ),
        ])

        let exported = NativeToolSchemaExport.exportSchemas(from: catalog)

        #expect(exported.count == 1)
        #expect(exported[0].metadataJson == nil)
    }

    @Test
    func riskMismatchExportsMoreRestrictiveRisk() throws {
        let manifest = NativeToolManifest(
            manifestId: "native.reminders.create_reminder.v1",
            capabilityId: "reminders.create_reminder",
            title: "Create Reminder",
            description: "Create reminders",
            mode: .background,
            permissionScope: NativePermissionScope("reminders"),
            requiredPrivacyKeys: ["NSRemindersUsageDescription"],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .openSettings, message: "Reminders access is required."),
            riskLevel: .confirm,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Create Reminder", resultSummaryPolicy: .metadataOnly)
        )
        let catalog = try NativeToolCatalog(tools: [
            ExportStubTool(
                schema: NativeToolSchema(
                    name: "reminders.create_reminder",
                    description: "Create reminders",
                    inputSchema: .object(properties: ["title": .string()], required: ["title"]),
                    riskLevel: .readOnly,
                    permissionScope: NativePermissionScope("reminders"),
                    availability: .available,
                    manifest: manifest
                )
            ),
        ])

        let exported = NativeToolSchemaExport.exportSchemas(from: catalog)
        let metadata = try #require(exported[0].metadataJson)
        let metadataData = try #require(metadata.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])

        #expect(exported[0].riskLevel == .confirm)
        #expect(object["risk_level"] as? String == "confirm")
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
