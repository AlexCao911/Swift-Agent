import Testing
@testable import LocalAgentLLMCloud

@Suite("Single cloud transport")
struct SingleCloudTransportTests {
    @Test
    func everyShippedPresetHasExactlyOneAuthFreeSemanticAdapter() throws {
        let registry = try CloudProviderAdapterRegistry.shipped()

        #expect(registry.presetIDs == Set(ProviderPreset.shipped.map(\.id)))
        #expect(registry.adapterIDs == Set(
            ProviderPreset.shipped.map(\.semanticAdapterID)
        ))
        #expect(registry.adapterIDs.count == ProviderPreset.shipped.count)
        let antigravity = try #require(ProviderPreset.shipped.first {
            $0.id == .antigravity
        })
        #expect(antigravity.authentication == .bearerAuthorization)
        #expect(antigravity.semanticAdapterID == "antigravity.cloud_code")
    }
}
