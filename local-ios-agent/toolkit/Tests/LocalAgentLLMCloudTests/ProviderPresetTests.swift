import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud provider presets")
struct ProviderPresetTests {
    @Test
    func shippedPresetsHaveExactIDsOriginsAndStrategies() throws {
        let presets = ProviderPreset.shipped

        #expect(presets.map(\.id.rawValue) == [
            "openai", "anthropic", "gemini", "xai", "deepseek", "minimax", "glm",
        ])
        #expect(Set(presets.map(\.id)).count == 7)
        #expect(presets.allSatisfy { preset in
            preset.defaultBaseURL.scheme == "https"
                && preset.defaultBaseURL.user == nil
                && preset.defaultBaseURL.password == nil
                && !preset.codecID.isEmpty
                && !preset.semanticAdapterID.isEmpty
        })

        #expect(try #require(presets[id: .openAI]).defaultBaseURL.absoluteString
            == "https://api.openai.com/v1")
        #expect(try #require(presets[id: .anthropic]).codecID == "anthropic_messages")
        #expect(try #require(presets[id: .gemini]).authentication == .googleAPIKeyHeader)
        #expect(try #require(presets[id: .xAI]).codecID == "openai_responses")
        #expect(try #require(presets[id: .deepSeek]).codecID == "openai_chat_completions")
        #expect(try #require(presets[id: .miniMax]).semanticAdapterID == "minimax.messages")
        #expect(try #require(presets[id: .glm]).discovery == .catalogAndManual)
    }
}

private extension [ProviderPreset] {
    subscript(id id: ProviderPresetID) -> ProviderPreset? {
        first { $0.id == id }
    }
}
