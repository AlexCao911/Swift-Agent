import Foundation
import Testing
@testable import LocalAgentLLMCloud

@Suite("OpenMinis provider product mapping")
struct OpenMinisProviderProductMappingTests {
    @Test
    func mapsProductTypesOntoTheExistingCodecFamilies() throws {
        let expected: [(String, ProviderCodecFamily, ProviderPresetID?)] = [
            ("openAI", .openAIChatCompletions, .openAIChatCompletions),
            ("openAIResponses", .openAIResponses, .openAI),
            ("anthropic", .anthropicMessages, .anthropic),
            ("gemini", .geminiInteractions, .gemini),
            ("openRouter", .openAIChatCompletions, .openRouter),
            ("xAI", .openAIResponses, .xAI),
            ("kimiCode", .openAIChatCompletions, .kimiCode),
            ("antigravity", .antigravityCloudCode, nil),
        ]

        for (rawValue, codec, presetID) in expected {
            let mapping = ProviderProductCompatibility.mapping(
                rawProviderType: rawValue
            )
            #expect(mapping.codecFamily == codec)
            #expect(mapping.presetID == presetID)
        }
    }

    @Test
    func openRouterAndKimiReuseOneOpenAICompatibleCodec() {
        let openRouter = ProviderProductCompatibility.mapping(
            rawProviderType: "openRouter"
        )
        let kimi = ProviderProductCompatibility.mapping(
            rawProviderType: "kimiCode"
        )

        #expect(openRouter.codecFamily == .openAIChatCompletions)
        #expect(kimi.codecFamily == .openAIChatCompletions)
        #expect(openRouter.requiresDedicatedCodec == false)
        #expect(kimi.requiresDedicatedCodec == false)
    }

    @Test
    func antigravityAndUnknownTypesFailClosedBeforeNetwork() {
        let antigravity = ProviderProductCompatibility.mapping(
            rawProviderType: "antigravity"
        )
        let unknown = ProviderProductCompatibility.mapping(
            rawProviderType: "futureProvider"
        )

        #expect(antigravity.requiresDedicatedCodec)
        #expect(!antigravity.isGenerationSupported)
        #expect(unknown.productType == .unsupported("futureProvider"))
        #expect(unknown.presetID == nil)
        #expect(!unknown.isGenerationSupported)
    }

    @Test
    func unsupportedProductTypeRoundTripsItsOriginalRawValue() throws {
        let type = ProviderProductType.unsupported("futureProvider")
        let data = try JSONEncoder().encode(type)
        let decoded = try JSONDecoder().decode(
            ProviderProductType.self,
            from: data
        )

        #expect(decoded == type)
        #expect(decoded.rawValue == "futureProvider")
    }
}
