import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

package struct ResolvedCloudGenerationConfiguration: Equatable, Sendable {
    package let semantic: GenerationConfiguration
    package let providerFields: CanonicalJSONValue
    package let digest: String
}

package enum CloudModelRouteSource: Equatable, Sendable {
    case catalog(CloudModelCatalogEntry)
    case manual(adapterID: String, modelID: String)
}

package enum CloudGenerationConfigurationResolver {
    package static func resolve(
        entry: CloudModelCatalogEntry,
        targetDefaults: GenerationConfiguration = GenerationConfiguration(),
        hostOverrides: GenerationConfiguration = GenerationConfiguration()
    ) throws -> ResolvedCloudGenerationConfiguration {
        let semantic = try LLMParameterSystem.resolve(
            modelDefaults: entry.parameterDefaults,
            targetDefaults: targetDefaults,
            hostOverrides: hostOverrides,
            schema: entry.parameterSchema
        )
        let providerFields = try mapProviderFields(
            semantic,
            adapterID: entry.adapterID
        )
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "adapter_id", value: .string(entry.adapterID)),
            .init(name: "model_id", value: .string(entry.identity.modelID)),
            .init(name: "model_revision", value: .string(entry.identity.modelRevision)),
            .init(name: "semantic", value: try semanticDocument(semantic)),
            .init(name: "provider_fields", value: providerFields),
        ])
        return ResolvedCloudGenerationConfiguration(
            semantic: semantic,
            providerFields: providerFields,
            digest: try CanonicalDigestV1.digest(
                domain: "resolved-parameters:v1",
                document: document
            ).hex
        )
    }

    package static func resolveManual(
        adapterID: String,
        modelID: String,
        targetDefaults: GenerationConfiguration = GenerationConfiguration(),
        hostOverrides: GenerationConfiguration = GenerationConfiguration()
    ) throws -> ResolvedCloudGenerationConfiguration {
        guard !adapterID.isEmpty, !modelID.isEmpty else {
            throw resolverFailure(
                "cloud_parameters.manual_route_invalid",
                "manual cloud route identity is empty"
            )
        }
        guard targetDefaults.parameters.isEmpty,
              hostOverrides.parameters.isEmpty
        else {
            throw resolverFailure(
                "cloud_parameters.manual_parameter_unsupported",
                "manual cloud routes do not accept unverified generation parameters"
            )
        }
        let semantic = GenerationConfiguration()
        let providerFields = try CanonicalJSONValue.object(entries: [])
        let document = try CanonicalJSONValue.object(entries: [
            .init(name: "schema_version", value: .string("1")),
            .init(name: "adapter_id", value: .string(adapterID)),
            .init(name: "model_id", value: .string(modelID)),
            .init(name: "model_revision", value: .null),
            .init(name: "route_source", value: .string("manual")),
            .init(name: "semantic", value: try semanticDocument(semantic)),
            .init(name: "provider_fields", value: providerFields),
        ])
        return ResolvedCloudGenerationConfiguration(
            semantic: semantic,
            providerFields: providerFields,
            digest: try CanonicalDigestV1.digest(
                domain: "resolved-parameters:v1",
                document: document
            ).hex
        )
    }

    package static func pruneForModelSwitch(
        _ configuration: GenerationConfiguration,
        to entry: CloudModelCatalogEntry
    ) -> GenerationConfiguration {
        let retained = configuration.parameters.filter { rawID, value in
            guard let definition = entry.parameterSchema.definition(
                for: LLMParameterID(rawValue: rawID)
            ), definition.support == .supported else { return false }
            return (try? LLMParameterSystem.resolve(
                hostOverrides: GenerationConfiguration(parameters: [rawID: value]),
                schema: LLMParameterSchema(definitions: [definition])
            )) != nil
        }
        return GenerationConfiguration(parameters: retained)
    }

    package static func validateCatalogEntry(_ entry: CloudModelCatalogEntry) throws {
        let supported = supportedParameterIDs(adapterID: entry.adapterID)
        guard entry.parameterDefinitions.allSatisfy({ definition in
            definition.support != .supported || supported.contains(definition.id)
        }) else {
            throw resolverFailure(
                "cloud_parameters.mapping_missing",
                "catalog declares a supported semantic parameter without an adapter mapping"
            )
        }
        _ = try resolve(entry: entry)
    }

    private static func mapProviderFields(
        _ configuration: GenerationConfiguration,
        adapterID: String
    ) throws -> CanonicalJSONValue {
        let unsupported = Set(configuration.parameters.keys).subtracting(
            supportedParameterIDs(adapterID: adapterID)
        )
        guard unsupported.isEmpty else {
            throw resolverFailure(
                "cloud_parameters.mapping_missing",
                "supported semantic parameter has no provider mapping"
            )
        }
        switch adapterID {
        case "openai.responses", "xai.responses":
            return try responsesFields(configuration, adapterID: adapterID)
        case "anthropic.messages", "minimax.messages":
            return try messagesFields(configuration, adapterID: adapterID)
        case "gemini.interactions":
            return try geminiFields(configuration)
        case "deepseek.chat_completions", "glm.chat_completions":
            return try chatFields(configuration, adapterID: adapterID)
        default:
            throw resolverFailure(
                "cloud_parameters.adapter_unknown",
                "cloud parameter adapter is unknown"
            )
        }
    }

    private static func responsesFields(
        _ configuration: GenerationConfiguration,
        adapterID: String
    ) throws -> CanonicalJSONValue {
        var fields: [String: CanonicalJSONValue] = [:]
        try copy(.samplingTemperature, from: configuration, to: "temperature", in: &fields)
        try copy(.samplingTopP, from: configuration, to: "top_p", in: &fields)
        try copy(.generationMaxOutputTokens, from: configuration, to: "max_output_tokens", in: &fields)
        try copy(.generationStopSequences, from: configuration, to: "stop", in: &fields)
        if let value = configuration.value(for: .reasoningEffort) {
            fields["reasoning"] = try object(["effort": parameterValue(value)])
        }
        if adapterID == "openai.responses",
           let value = configuration.value(for: .outputVerbosity) {
            fields["text"] = try object(["verbosity": parameterValue(value)])
        }
        return try object(fields)
    }

    private static func messagesFields(
        _ configuration: GenerationConfiguration,
        adapterID: String
    ) throws -> CanonicalJSONValue {
        var fields: [String: CanonicalJSONValue] = [:]
        try copy(.samplingTemperature, from: configuration, to: "temperature", in: &fields)
        try copy(.samplingTopP, from: configuration, to: "top_p", in: &fields)
        try copy(.generationMaxOutputTokens, from: configuration, to: "max_tokens", in: &fields)
        if adapterID == "anthropic.messages" {
            try copy(.samplingTopK, from: configuration, to: "top_k", in: &fields)
            try copy(.generationStopSequences, from: configuration, to: "stop_sequences", in: &fields)
        }
        if let value = configuration.value(for: .reasoningTokenBudget) {
            fields["thinking"] = try object([
                "budget_tokens": parameterValue(value),
                "type": .string("enabled"),
            ])
        }
        return try object(fields)
    }

    private static func geminiFields(
        _ configuration: GenerationConfiguration
    ) throws -> CanonicalJSONValue {
        var generation: [String: CanonicalJSONValue] = [:]
        try copy(.samplingTemperature, from: configuration, to: "temperature", in: &generation)
        try copy(.samplingTopP, from: configuration, to: "top_p", in: &generation)
        try copy(.generationMaxOutputTokens, from: configuration, to: "max_output_tokens", in: &generation)
        try copy(.generationSeed, from: configuration, to: "seed", in: &generation)
        try copy(.generationStopSequences, from: configuration, to: "stop_sequences", in: &generation)
        try copy(.reasoningEffort, from: configuration, to: "thinking_level", in: &generation)
        if let value = configuration.parameters["thinking.display"] {
            guard case let .text(display) = value else { throw invalidParameterValue() }
            generation["thinking_summaries"] = .string(
                display == "summarized" ? "auto" : "none"
            )
        }
        return try object(["generation_config": try object(generation)])
    }

    private static func chatFields(
        _ configuration: GenerationConfiguration,
        adapterID: String
    ) throws -> CanonicalJSONValue {
        var fields: [String: CanonicalJSONValue] = [:]
        try copy(.samplingTemperature, from: configuration, to: "temperature", in: &fields)
        try copy(.samplingTopP, from: configuration, to: "top_p", in: &fields)
        try copy(.generationMaxOutputTokens, from: configuration, to: "max_tokens", in: &fields)
        try copy(.generationStopSequences, from: configuration, to: "stop", in: &fields)
        if let value = configuration.value(for: .reasoningEffort) {
            guard case let .text(effort) = value else { throw invalidParameterValue() }
            let enabled = effort != "none"
            fields["thinking"] = try object([
                "type": .string(enabled ? "enabled" : "disabled"),
            ])
            if adapterID == "glm.chat_completions" {
                fields["clear_thinking"] = .bool(!enabled)
            }
        }
        return try object(fields)
    }

    private static func supportedParameterIDs(adapterID: String) -> Set<String> {
        let temperatureAndTopP: Set<String> = [
            LLMParameterID.samplingTemperature.rawValue,
            LLMParameterID.samplingTopP.rawValue,
            LLMParameterID.generationMaxOutputTokens.rawValue,
        ]
        switch adapterID {
        case "openai.responses":
            return temperatureAndTopP.union([
                LLMParameterID.generationStopSequences.rawValue,
                LLMParameterID.reasoningEffort.rawValue,
                LLMParameterID.outputVerbosity.rawValue,
            ])
        case "xai.responses":
            return temperatureAndTopP.union([
                LLMParameterID.generationStopSequences.rawValue,
                LLMParameterID.reasoningEffort.rawValue,
            ])
        case "anthropic.messages":
            return temperatureAndTopP.union([
                LLMParameterID.samplingTopK.rawValue,
                LLMParameterID.generationStopSequences.rawValue,
                LLMParameterID.reasoningTokenBudget.rawValue,
            ])
        case "minimax.messages":
            return temperatureAndTopP.union([LLMParameterID.reasoningTokenBudget.rawValue])
        case "gemini.interactions":
            return temperatureAndTopP.union([
                LLMParameterID.generationSeed.rawValue,
                LLMParameterID.generationStopSequences.rawValue,
                LLMParameterID.reasoningEffort.rawValue,
                "thinking.display",
            ])
        case "deepseek.chat_completions", "glm.chat_completions":
            return temperatureAndTopP.union([
                LLMParameterID.generationStopSequences.rawValue,
                LLMParameterID.reasoningEffort.rawValue,
            ])
        default:
            return []
        }
    }

    private static func copy(
        _ id: LLMParameterID,
        from configuration: GenerationConfiguration,
        to field: String,
        in fields: inout [String: CanonicalJSONValue]
    ) throws {
        if let value = configuration.value(for: id) {
            fields[field] = try parameterValue(value)
        }
    }

    private static func object(
        _ values: [String: CanonicalJSONValue]
    ) throws -> CanonicalJSONValue {
        try .object(entries: values.sorted(by: { $0.key < $1.key }).map {
            .init(name: $0.key, value: $0.value)
        })
    }

    private static func semanticDocument(
        _ configuration: GenerationConfiguration
    ) throws -> CanonicalJSONValue {
        try .object(entries: configuration.parameters.sorted(by: { $0.key < $1.key }).map {
            .init(name: $0.key, value: try semanticParameterValue($0.value))
        })
    }

    private static func semanticParameterValue(
        _ value: LLMParameterValue
    ) throws -> CanonicalJSONValue {
        let type: String
        let encoded: CanonicalJSONValue
        switch value {
        case let .decimal(number):
            type = "decimal"
            encoded = .number(number)
        case let .integer(number):
            type = "integer"
            encoded = .string(String(number))
        case let .text(text):
            type = "text"
            encoded = .string(text)
        case let .boolean(value):
            type = "boolean"
            encoded = .bool(value)
        case let .textList(values):
            type = "text_list"
            encoded = .array(values.map(CanonicalJSONValue.string))
        }
        return try object(["type": .string(type), "value": encoded])
    }

    private static func parameterValue(_ value: LLMParameterValue) throws -> CanonicalJSONValue {
        switch value {
        case let .decimal(number): return .number(number)
        case let .integer(number):
            guard abs(Double(number)) <= 9_007_199_254_740_991,
                  Int64(Double(number)) == number
            else { throw invalidParameterValue() }
            return .number(Double(number))
        case let .text(text): return .string(text)
        case let .boolean(value): return .bool(value)
        case let .textList(values): return .array(values.map(CanonicalJSONValue.string))
        }
    }

    private static func invalidParameterValue() -> LLMFailure {
        resolverFailure(
            "cloud_parameters.value_not_canonical",
            "provider parameter value cannot be represented canonically"
        )
    }
}

private func resolverFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
