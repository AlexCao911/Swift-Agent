import Testing
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore

@Suite("LLM parameter system")
struct LLMParameterSystemTests {
    @Test
    func hostOverridesWinWithoutProviderFieldNames() throws {
        let resolved = try LLMParameterSystem.resolve(
            modelDefaults: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.4)),
            targetDefaults: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.6)),
            hostOverrides: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.8)),
            schema: .init(definitions: [
                .decimal(.samplingTemperature, support: .supported, minimum: 0, maximum: 2),
            ])
        )

        #expect(resolved.value(for: .samplingTemperature) == .decimal(0.8))
    }

    @Test
    func unsupportedAndOutOfRangeValuesAreRejected() {
        assertParameterError("llm.parameter.unsupported") {
            try LLMParameterSystem.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.samplingTopK, to: .integer(40)),
                schema: .init(definitions: [
                    .integer(.samplingTopK, support: .unknown, minimum: 0, maximum: 100),
                ])
            )
        }
        assertParameterError("llm.parameter.out_of_range") {
            try LLMParameterSystem.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.samplingTopP, to: .decimal(1.5)),
                schema: .init(definitions: [
                    .decimal(.samplingTopP, support: .supported, minimum: 0, maximum: 1),
                ])
            )
        }
        assertParameterError("llm.parameter.out_of_range") {
            try LLMParameterSystem.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.samplingTemperature, to: .decimal(.nan)),
                schema: .init(definitions: [
                    .decimal(.samplingTemperature, support: .supported, minimum: 0, maximum: 2),
                ])
            )
        }
    }

    @Test
    func mutualExclusionAndConditionalDisableAreRejected() {
        let schema = LLMParameterSchema(definitions: [
            .decimal(
                .samplingTemperature,
                support: .supported,
                minimum: 0,
                maximum: 2,
                mutuallyExclusiveWith: [.samplingTopP]
            ),
            .decimal(.samplingTopP, support: .supported, minimum: 0, maximum: 1),
            .choice(.reasoningEffort, support: .supported, choices: ["low", "high"]),
            .integer(
                .samplingTopK,
                support: .supported,
                minimum: 0,
                maximum: 100,
                disabledWhen: .equals(.reasoningEffort, .text("high"))
            ),
        ])

        assertParameterError("llm.parameter.mutually_exclusive") {
            try LLMParameterSystem.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.samplingTemperature, to: .decimal(0.7))
                    .setting(.samplingTopP, to: .decimal(0.9)),
                schema: schema
            )
        }
        assertParameterError("llm.parameter.conditionally_disabled") {
            try LLMParameterSystem.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.reasoningEffort, to: .text("high"))
                    .setting(.samplingTopK, to: .integer(40)),
                schema: schema
            )
        }
    }
}

private func assertParameterError<T>(
    _ expectedCode: String,
    operation: () throws -> T
) {
    do {
        _ = try operation()
        Issue.record("expected LLMFailure with code \(expectedCode)")
    } catch let failure as LLMFailure {
        #expect(failure.code == expectedCode)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
