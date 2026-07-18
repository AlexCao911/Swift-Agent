import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCloud

@Suite("Cloud generation configuration resolver")
struct CloudGenerationConfigurationResolverTests {
    @Test
    func resolvesModelTargetHostPrecedenceAndMapsProviderFields() throws {
        let resolved = try CloudGenerationConfigurationResolver.resolve(
            entry: cloudParameterEntry(),
            targetDefaults: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.4))
                .setting(.samplingTopP, to: .decimal(0.9)),
            hostOverrides: GenerationConfiguration()
                .setting(.samplingTemperature, to: .decimal(0.7))
                .setting(.generationMaxOutputTokens, to: .integer(64))
        )
        #expect(resolved.semantic.value(for: .samplingTemperature) == .decimal(0.7))
        #expect(resolved.semantic.value(for: .samplingTopP) == .decimal(0.9))
        #expect(resolved.semantic.value(for: .generationMaxOutputTokens) == .integer(64))
        #expect(resolved.providerFields.objectValue(forKey: "temperature") == .number(0.7))
        #expect(resolved.providerFields.objectValue(forKey: "top_p") == .number(0.9))
        #expect(resolved.providerFields.objectValue(forKey: "max_output_tokens") == .number(64))
        #expect(resolved.digest.count == 64)
    }

    @Test
    func rejectsUnsupportedIgnoredAndConflictingReasoningControls() {
        expectCloudResolverFailure("llm.parameter.unsupported") {
            _ = try CloudGenerationConfigurationResolver.resolve(
                entry: cloudParameterEntry(),
                hostOverrides: GenerationConfiguration().setting(.samplingTopK, to: .integer(40))
            )
        }
        expectCloudResolverFailure("llm.parameter.mutually_exclusive") {
            _ = try CloudGenerationConfigurationResolver.resolve(
                entry: cloudParameterEntry(),
                hostOverrides: GenerationConfiguration()
                    .setting(.samplingTemperature, to: .decimal(0.7))
                    .setting(.reasoningEffort, to: .text("high"))
            )
        }
    }

    @Test
    func mapsNestedReasoningAndProviderSpecificGenerationObjects() throws {
        let openAI = try CloudGenerationConfigurationResolver.resolve(
            entry: parameterEntry(
                adapterID: "openai.responses",
                definitions: [
                    .init(id: .reasoningEffort, valueType: .text, choices: ["high"]),
                    .init(id: .outputVerbosity, valueType: .text, choices: ["low"]),
                ]
            ),
            hostOverrides: GenerationConfiguration()
                .setting(.reasoningEffort, to: .text("high"))
                .setting(.outputVerbosity, to: .text("low"))
        )
        #expect(openAI.providerFields.objectValue(forKey: "reasoning")?.objectValue(forKey: "effort") == .string("high"))
        #expect(openAI.providerFields.objectValue(forKey: "text")?.objectValue(forKey: "verbosity") == .string("low"))

        let anthropic = try CloudGenerationConfigurationResolver.resolve(
            entry: parameterEntry(
                adapterID: "anthropic.messages",
                definitions: [.init(
                    id: .reasoningTokenBudget,
                    valueType: .integer,
                    minimum: 1,
                    maximum: 8_000
                )]
            ),
            hostOverrides: GenerationConfiguration()
                .setting(.reasoningTokenBudget, to: .integer(4_096))
        )
        let thinking = try #require(anthropic.providerFields.objectValue(forKey: "thinking"))
        #expect(thinking.objectValue(forKey: "type") == .string("enabled"))
        #expect(thinking.objectValue(forKey: "budget_tokens") == .number(4_096))

        let gemini = try CloudGenerationConfigurationResolver.resolve(
            entry: parameterEntry(
                adapterID: "gemini.interactions",
                definitions: [.init(id: .reasoningEffort, valueType: .text, choices: ["high"])]
            ),
            hostOverrides: GenerationConfiguration().setting(.reasoningEffort, to: .text("high"))
        )
        #expect(gemini.providerFields.objectValue(forKey: "generation_config")?.objectValue(forKey: "thinking_level") == .string("high"))
    }

    @Test
    func prunesUnsupportedOrInvalidValuesOnModelSwitch() {
        let old = GenerationConfiguration()
            .setting(.samplingTemperature, to: .decimal(0.5))
            .setting(.samplingTopK, to: .integer(40))
            .setting(.generationMaxOutputTokens, to: .integer(99_999))
        let pruned = CloudGenerationConfigurationResolver.pruneForModelSwitch(
            old,
            to: cloudParameterEntry()
        )
        #expect(pruned.value(for: .samplingTemperature) == .decimal(0.5))
        #expect(pruned.value(for: .samplingTopK) == nil)
        #expect(pruned.value(for: .generationMaxOutputTokens) == nil)
    }
}

private func cloudParameterEntry() -> CloudModelCatalogEntry {
    CloudModelCatalogEntry(
        identity: CloudModelCatalogIdentity(
            presetID: .openAI,
            modelID: "fixture-model",
            modelRevision: "2026-01"
        ),
        adapterID: "openai.responses",
        minimumAdapterVersion: 1,
        maximumAdapterVersion: 1,
        capabilities: [.init(capabilityID: "text_generation", value: .support(.supported))],
        parameterDefinitions: cloudTestParameterDefinitions,
        parameterDefaults: GenerationConfiguration()
            .setting(.samplingTemperature, to: .decimal(0.2))
            .setting(.generationMaxOutputTokens, to: .integer(256)),
        continuationModes: [.statelessRequired]
    )
}

private func parameterEntry(
    adapterID: String,
    definitions: [CloudCatalogParameterDefinition]
) -> CloudModelCatalogEntry {
    CloudModelCatalogEntry(
        identity: CloudModelCatalogIdentity(
            presetID: .openAI,
            modelID: "fixture-model",
            modelRevision: "1"
        ),
        adapterID: adapterID,
        minimumAdapterVersion: 1,
        maximumAdapterVersion: 1,
        capabilities: [.init(capabilityID: "text_generation", value: .support(.supported))],
        parameterDefinitions: definitions,
        parameterDefaults: GenerationConfiguration(),
        continuationModes: [.statelessRequired]
    )
}

private func expectCloudResolverFailure(
    _ code: String,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("expected \(code)")
    } catch let failure as LLMFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
