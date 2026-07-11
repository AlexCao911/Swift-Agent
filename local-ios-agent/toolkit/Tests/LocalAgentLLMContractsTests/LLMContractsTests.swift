import Foundation
import Testing
@testable import LocalAgentLLMContracts

@Suite("LLM contracts")
struct LLMContractsTests {
    @Test
    func generationConfigurationRoundTripsSemanticParameters() throws {
        let configuration = GenerationConfiguration()
            .setting(.samplingTemperature, to: .decimal(0.7))
            .setting(.samplingTopK, to: .integer(40))
            .setting(.reasoningEffort, to: .text("medium"))

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(GenerationConfiguration.self, from: data)

        #expect(decoded == configuration)
        #expect(decoded.value(for: .samplingTemperature) == .decimal(0.7))
    }

    @Test
    func failureCarriesStableProviderNeutralCode() {
        let failure = LLMFailure(
            code: "llm.parameter.unsupported",
            message: "parameter is unsupported",
            retryable: false
        )

        #expect(failure.code == "llm.parameter.unsupported")
        #expect(!failure.retryable)
    }

    @Test
    func agentInputRoundTripsTextAndOpaqueMultimodalReferences() throws {
        let input = AgentLLMInput(
            inputID: "input.turn.1",
            messages: [
                LLMInputMessage(
                    role: .user,
                    content: [
                        .text("Describe this image"),
                        .attachment(
                            modality: .image,
                            attachmentID: "attachment.opaque.1",
                            mediaType: "image/heic"
                        ),
                    ]
                ),
            ]
        )

        let decoded = try JSONDecoder().decode(
            AgentLLMInput.self,
            from: JSONEncoder().encode(input)
        )

        #expect(decoded == input)
    }
}
