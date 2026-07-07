import LocalAgentBridge
import LocalNativeToolkit
import Testing
@testable import LocalAgentApp

@Suite("Agent builder tool catalog")
struct AgentBuilderToolCatalogTests {
    @Test("tool catalog projects native manifests into Builder cards")
    func catalogProjectsManifestMetadata() async throws {
        let catalog = try NativeToolCatalog(tools: [
            BuilderToolStub(
                name: "web.fetch_url_text",
                manifest: NativeToolManifest(
                    manifestId: "native.web.fetch_url_text.v1",
                    capabilityId: "web.fetch_url_text",
                    title: "Fetch Web Page",
                    description: "Fetch bounded text from a public HTTPS page.",
                    mode: .background,
                    permissionScope: NativePermissionScope("web.fetch.approved"),
                    requiredPrivacyKeys: [],
                    requiresForegroundUI: false,
                    minimumOS: "iOS 17.0",
                    regionPolicy: "available",
                    fallback: NativeToolFallback(kind: .unavailable, message: "Cannot fetch this URL."),
                    riskLevel: .readOnly,
                    approvalPolicy: .perCall,
                    trustLevel: .untrustedExternalContent,
                    retention: .runOnly,
                    audit: NativeToolAudit(label: "Web Fetch", resultSummaryPolicy: .excerptOnly)
                )
            ),
        ])

        let client = NativeManifestToolCatalogClient(catalogProvider: { catalog })
        let cards = try await client.loadToolCards()

        #expect(cards.map(\.id) == ["web.fetch_url_text"])
        #expect(cards.first?.title == "Fetch Web Page")
        #expect(cards.first?.approvalPolicy == "per_call")
        #expect(cards.first?.trustLevel == "untrusted_external_content")
        #expect(cards.first?.isAvailable == true)
    }

    @Test("tools without stable manifest metadata are unavailable")
    func missingMetadataIsUnavailable() async throws {
        let client = StaticAgentBuilderToolCatalogClient(cards: [
            AgentBuilderToolCard.unavailable(
                id: "legacy.tool",
                name: "legacy.tool",
                reason: "Missing stable NativeToolManifest metadata."
            ),
        ])

        let cards = try await client.loadToolCards()

        #expect(cards.first?.isAvailable == false)
        #expect(cards.first?.statusText == "Missing stable NativeToolManifest metadata.")
    }
}

private struct BuilderToolStub: NativeTool {
    let schema: NativeToolSchema

    init(name: String, manifest: NativeToolManifest) {
        self.schema = NativeToolSchema(
            name: name,
            description: manifest.description,
            inputSchema: .object(),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    func execute(argumentsJson: String) async -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: schema.manifest?.manifestId ?? "stub",
            toolName: schema.name,
            toolCallId: "stub",
            code: "stub",
            displayText: "stub",
            auditSummary: "stub"
        )
    }
}
