import Testing
@testable import LocalAgentApp

@Suite("Unified model picker")
struct UnifiedModelPickerTests {
    @Test
    func combinesReadyLocalAndCloudModelsWithoutStartingGeneration() {
        let options = UnifiedModelPickerProjection.options(
            in: .fixture
        )

        #expect(options.map(\.selection) == [
            .local(engineID: "installation-1", modelID: "official-1"),
            .cloud(providerConfigurationID: "profile", modelID: "reasoning-model"),
        ])
        #expect(options.map(\.section) == [.onDevice, .cloud])
    }

    @Test
    func incompatibleLocalInstallationIsNotSelectable() {
        let options = UnifiedModelPickerProjection.options(
            in: .incompatibleFixture
        )

        #expect(!options.contains { option in
            if case .local = option.selection { true } else { false }
        })
    }
}
