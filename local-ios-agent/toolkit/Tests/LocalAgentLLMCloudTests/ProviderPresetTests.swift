import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud provider presets")
struct ProviderPresetTests {
    @Test
    func shippedPresetsHaveExactIDsOriginsAndStrategies() throws {
        let presets = ProviderPreset.shipped

        #expect(presets.map(\.id.rawValue) == [
            "openai",
            "openai_chat_completions",
            "anthropic",
            "gemini",
            "xai",
            "deepseek",
            "minimax",
            "glm",
            "openrouter",
            "kimi_code",
        ])
        #expect(Set(presets.map(\.id)).count == 10)
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
        #expect(try #require(presets[id: .openAIChatCompletions]).codecID
            == "openai_chat_completions")
        #expect(try #require(presets[id: .openRouter]).semanticAdapterID
            == "openrouter.chat_completions")
        #expect(try #require(presets[id: .kimiCode]).discovery
            == .catalogAndManual)
    }
}

private extension [ProviderPreset] {
    subscript(id id: ProviderPresetID) -> ProviderPreset? {
        first { $0.id == id }
    }
}
