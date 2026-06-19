import Foundation
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Meta native tools")
struct MetaToolsTests {
    @Test
    func listToolsReportsAvailableSchemasAsPublicRunScopedResult() async throws {
        let catalog = try NativeToolCatalog(tools: [
            MetaStubTool(name: "zeta.tool", riskLevel: .confirm, permissionScope: "zeta.scope"),
            MetaStubTool(name: "alpha.tool", riskLevel: .readOnly, permissionScope: nil),
        ])
        let tool = NativeListToolsTool(catalog: catalog)

        #expect(tool.schema.name == "native.list_tools")
        #expect(tool.schema.riskLevel == .readOnly)
        #expect(tool.schema.permissionScope == nil)

        let result = await tool.execute(argumentsJson: "{}")
        let object = try decodedJSONObject(result.structuredJson)
        let tools = try #require(object["tools"] as? [[String: Any]])

        #expect(result.sensitivity == .public)
        #expect(result.retention == .runOnly)
        #expect(result.isError == false)
        #expect(tools.count == 2)
        #expect(tools.map { $0["name"] as? String } == ["alpha.tool", "zeta.tool"])
        if tools.count == 2 {
            #expect(tools[0]["risk_level"] as? String == "read_only")
            #expect(tools[1]["permission_scope"] as? String == "zeta.scope")
        }
    }

    @Test
    func listToolsCanReportTheFinalCatalogIncludingMetaTools() async throws {
        let catalogBox = CatalogBox(try NativeToolCatalog(tools: []))
        let permissionStore = PermissionStore()
        let listTool = NativeListToolsTool(catalogProvider: { catalogBox.catalog })
        let permissionTool = NativePermissionStatusTool(permissionStore: permissionStore)

        catalogBox.catalog = try NativeToolCatalog(tools: [
            MetaStubTool(name: "alpha.tool", riskLevel: .readOnly, permissionScope: nil),
            listTool,
            permissionTool,
        ])

        let result = await listTool.execute(argumentsJson: "{}")
        let object = try decodedJSONObject(result.structuredJson)
        let tools = try #require(object["tools"] as? [[String: Any]])

        #expect(tools.map { $0["name"] as? String } == [
            "alpha.tool",
            "native.list_tools",
            "native.permission_status",
        ])
    }

    @Test
    func permissionStatusReportsPermissionStoreStatesAsPublicRunScopedResult() async throws {
        let store = PermissionStore()
        await store.setState(.granted, for: NativePermissionScope("calendar.events"))
        await store.setState(.denied, for: NativePermissionScope("reminders"))
        let tool = NativePermissionStatusTool(permissionStore: store)

        #expect(tool.schema.name == "native.permission_status")
        #expect(tool.schema.riskLevel == .readOnly)
        #expect(tool.schema.permissionScope == nil)

        let result = await tool.execute(argumentsJson: "{}")
        let object = try decodedJSONObject(result.structuredJson)
        let permissions = try #require(object["permissions"] as? [[String: Any]])

        #expect(result.sensitivity == .public)
        #expect(result.retention == .runOnly)
        #expect(result.isError == false)
        #expect(permissions.count == 2)
        #expect(permissions.map { $0["scope"] as? String } == ["calendar.events", "reminders"])
        #expect(permissions.map { $0["state"] as? String } == ["granted", "denied"])
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class CatalogBox: @unchecked Sendable {
    var catalog: NativeToolCatalog

    init(_ catalog: NativeToolCatalog) {
        self.catalog = catalog
    }
}

private struct MetaStubTool: NativeTool {
    var schema: NativeToolSchema

    init(name: String, riskLevel: NativeToolRiskLevel, permissionScope: NativePermissionScope?) {
        self.schema = NativeToolSchema(
            name: name,
            description: "Meta stub",
            inputSchema: .object(),
            riskLevel: riskLevel,
            permissionScope: permissionScope,
            availability: .available
        )
    }

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
