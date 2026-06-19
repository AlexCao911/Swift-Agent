import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Native tool catalog")
struct NativeToolCatalogTests {
    @Test
    func catalogReturnsSchemasInDeterministicNameOrder() throws {
        let catalog = try NativeToolCatalog(tools: [
            StubNativeTool(name: "zeta.tool"),
            StubNativeTool(name: "alpha.tool"),
            StubNativeTool(name: "middle.tool"),
        ])

        #expect(catalog.schemas.map(\.name) == [
            "alpha.tool",
            "middle.tool",
            "zeta.tool",
        ])
    }

    @Test
    func catalogRejectsDuplicateToolNames() {
        #expect(throws: NativeToolCatalogError.duplicateToolName("duplicate.tool")) {
            _ = try NativeToolCatalog(tools: [
                StubNativeTool(name: "duplicate.tool"),
                StubNativeTool(name: "duplicate.tool"),
            ])
        }
    }
}

private struct StubNativeTool: NativeTool {
    var schema: NativeToolSchema

    init(name: String) {
        self.schema = NativeToolSchema(
            name: name,
            description: "A stub tool",
            inputSchema: .object(),
            riskLevel: .readOnly,
            permissionScope: nil,
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
