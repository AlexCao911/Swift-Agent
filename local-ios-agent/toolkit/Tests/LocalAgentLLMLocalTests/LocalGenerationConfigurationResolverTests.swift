import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local generation configuration resolver")
struct LocalGenerationConfigurationResolverTests {
    @Test
    func resolvesEveryPrecedenceEdgeAndMapsSemanticIDs() throws {
        let resolved = try LocalGenerationConfigurationResolver.resolve(
            catalogDefaults: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.2))
                .setting(.generationMaxOutputTokens, to: .integer(256)),
            targetDefaults: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.4)),
            hostOverrides: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.6))
                .setting(.samplingRepetitionPenalty, to: .decimal(1.1)),
            schema: schema,
            engineParameters: engineParameters,
            devicePolicy: LocalDeviceGenerationPolicy(maximumOutputTokens: 64)
        )

        #expect(resolved.semantic.value(for: .samplingTemperature) == .decimal(0.6))
        #expect(resolved.semantic.value(for: .generationMaxOutputTokens) == .integer(64))
        #expect(resolved.concreteOptions["temperature"] == .number(0.6))
        #expect(resolved.concreteOptions["repeat_penalty"] == .number(1.1))
        #expect(resolved.concreteOptions["max_new_tokens"] == .number(64))
    }

    @Test
    func mapsAllSupportedLocalControlsExactly() throws {
        let configuration = GenerationConfiguration()
            .setting(.samplingTemperature, to: .decimal(0.3))
            .setting(.samplingTopP, to: .decimal(0.9))
            .setting(.samplingTopK, to: .integer(40))
            .setting(.samplingMinP, to: .decimal(0.05))
            .setting(.samplingRepetitionPenalty, to: .decimal(1.2))
            .setting(.generationMaxOutputTokens, to: .integer(128))
            .setting(.generationSeed, to: .integer(7))
            .setting(.generationStopSequences, to: .textList(["</tool>"]))
        let resolved = try LocalGenerationConfigurationResolver.resolve(
            catalogDefaults: configuration,
            schema: schema,
            engineParameters: engineParameters + [
                CppParameterDescriptor(
                    backendOption: "stop_sequences",
                    valueType: "string_array",
                    minimum: nil,
                    maximum: nil
                ),
            ]
        )

        #expect(Set(resolved.concreteOptions.keys) == [
            "temperature", "top_p", "top_k", "min_p", "repeat_penalty",
            "max_new_tokens", "seed", "stop_sequences",
        ])
        #expect(resolved.concreteOptions["stop_sequences"] == .array([.string("</tool>")]))
    }

    @Test
    func rejectsUnsupportedEngineControlsAndManifestLoadOverrides() {
        expectResolverFailure("local_engine.parameter_unsupported") {
            try LocalGenerationConfigurationResolver.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.generationStopSequences, to: .textList(["stop"])),
                schema: schema,
                engineParameters: engineParameters
            )
        }
        expectResolverFailure("llm.parameter.unsupported") {
            try LocalGenerationConfigurationResolver.resolve(
                hostOverrides: GenerationConfiguration(parameters: [
                    "runtime.n_threads": .integer(99),
                ]),
                schema: schema,
                engineParameters: engineParameters
            )
        }
    }

    @Test
    func rejectsValuesOutsideTheConcreteEngineRange() {
        expectResolverFailure("local_engine.parameter_out_of_range") {
            try LocalGenerationConfigurationResolver.resolve(
                hostOverrides: GenerationConfiguration()
                    .setting(.samplingTopK, to: .integer(80)),
                schema: schema,
                engineParameters: engineParameters.map {
                    $0.backendOption == "top_k"
                        ? CppParameterDescriptor(
                            backendOption: "top_k",
                            valueType: "integer",
                            minimum: 0,
                            maximum: 50
                        )
                        : $0
                }
            )
        }
    }
}

private let schema = LLMParameterSchema(definitions: [
    .decimal(.samplingTemperature, support: .supported, minimum: 0, maximum: 2),
    .decimal(.samplingTopP, support: .supported, minimum: 0, maximum: 1),
    .integer(.samplingTopK, support: .supported, minimum: 0, maximum: 10_000),
    .decimal(.samplingMinP, support: .supported, minimum: 0, maximum: 1),
    .decimal(.samplingRepetitionPenalty, support: .supported, minimum: 0, maximum: 2),
    .integer(.generationMaxOutputTokens, support: .supported, minimum: 1, maximum: 32_768),
    .integer(.generationSeed, support: .supported, minimum: Int64.min, maximum: Int64.max),
    LLMParameterDefinition(
        id: .generationStopSequences,
        valueType: .textList,
        support: .supported
    ),
])

private let engineParameters = [
    CppParameterDescriptor(backendOption: "temperature", valueType: "number", minimum: 0, maximum: 2),
    CppParameterDescriptor(backendOption: "top_p", valueType: "number", minimum: 0, maximum: 1),
    CppParameterDescriptor(backendOption: "top_k", valueType: "integer", minimum: 0, maximum: 10_000),
    CppParameterDescriptor(backendOption: "min_p", valueType: "number", minimum: 0, maximum: 1),
    CppParameterDescriptor(backendOption: "repeat_penalty", valueType: "number", minimum: 0, maximum: 2),
    CppParameterDescriptor(backendOption: "max_new_tokens", valueType: "integer", minimum: 1, maximum: nil),
    CppParameterDescriptor(backendOption: "seed", valueType: "integer", minimum: nil, maximum: nil),
]

private func expectResolverFailure(
    _ expectedCode: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("expected resolver failure \(expectedCode)")
    } catch let failure as LLMFailure {
        #expect(failure.code == expectedCode)
    } catch {
        Issue.record("unexpected resolver error: \(error)")
    }
}
