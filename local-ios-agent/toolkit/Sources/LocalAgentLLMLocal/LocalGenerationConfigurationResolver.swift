import LocalAgentLLMContracts
import LocalAgentLLMCore

package struct LocalDeviceGenerationPolicy: Equatable, Sendable {
    package let maximumOutputTokens: Int64?

    package init(maximumOutputTokens: Int64? = nil) {
        self.maximumOutputTokens = maximumOutputTokens
    }
}

package struct ResolvedLocalGenerationConfiguration: Equatable, Sendable {
    package let semantic: GenerationConfiguration
    package let concreteOptions: [String: CanonicalJSONValue]
}

package enum LocalGenerationConfigurationResolver {
    private static let backendOptions: [String: String] = [
        LLMParameterID.samplingTemperature.rawValue: "temperature",
        LLMParameterID.samplingTopP.rawValue: "top_p",
        LLMParameterID.samplingTopK.rawValue: "top_k",
        LLMParameterID.samplingMinP.rawValue: "min_p",
        LLMParameterID.samplingRepetitionPenalty.rawValue: "repeat_penalty",
        LLMParameterID.generationMaxOutputTokens.rawValue: "max_new_tokens",
        LLMParameterID.generationSeed.rawValue: "seed",
        LLMParameterID.generationStopSequences.rawValue: "stop_sequences",
    ]

    package static func resolve(
        catalogDefaults: GenerationConfiguration = GenerationConfiguration(),
        targetDefaults: GenerationConfiguration = GenerationConfiguration(),
        hostOverrides: GenerationConfiguration = GenerationConfiguration(),
        schema: LLMParameterSchema,
        engineParameters: [CppParameterDescriptor],
        devicePolicy: LocalDeviceGenerationPolicy = LocalDeviceGenerationPolicy()
    ) throws -> ResolvedLocalGenerationConfiguration {
        var semantic = try LLMParameterSystem.resolve(
            modelDefaults: catalogDefaults,
            targetDefaults: targetDefaults,
            hostOverrides: hostOverrides,
            schema: schema
        )

        if let maximum = devicePolicy.maximumOutputTokens,
           case let .integer(requested)? = semantic.value(for: .generationMaxOutputTokens),
           requested > maximum
        {
            semantic = semantic.setting(.generationMaxOutputTokens, to: .integer(maximum))
        }

        let descriptors = Dictionary(
            engineParameters.map { ($0.backendOption, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var concrete: [String: CanonicalJSONValue] = [:]
        for (semanticID, value) in semantic.parameters {
            guard let backendOption = backendOptions[semanticID],
                  let descriptor = descriptors[backendOption]
            else {
                throw failure(
                    "local_engine.parameter_unsupported",
                    "compiled engine does not support semantic parameter: \(semanticID)"
                )
            }
            concrete[backendOption] = try concreteValue(value, descriptor: descriptor)
        }
        return ResolvedLocalGenerationConfiguration(
            semantic: semantic,
            concreteOptions: concrete
        )
    }

    private static func concreteValue(
        _ value: LLMParameterValue,
        descriptor: CppParameterDescriptor
    ) throws -> CanonicalJSONValue {
        let numeric: Double?
        let concrete: CanonicalJSONValue
        switch (descriptor.valueType, value) {
        case let ("number", .decimal(number)):
            numeric = number
            concrete = .number(number)
        case let ("integer", .integer(number)):
            let converted = Double(number)
            guard Int64(converted) == number else {
                throw failure(
                    "local_engine.parameter_out_of_range",
                    "integer parameter cannot be represented by the native JSON boundary"
                )
            }
            numeric = converted
            concrete = .number(converted)
        case let ("string_array", .textList(values)):
            numeric = nil
            concrete = .array(values.map(CanonicalJSONValue.string))
        default:
            throw failure(
                "local_engine.parameter_type_mismatch",
                "compiled engine parameter type does not match semantic parameter"
            )
        }

        if let numeric,
           descriptor.minimum.map({ numeric < $0 }) == true
            || descriptor.maximum.map({ numeric > $0 }) == true
        {
            throw failure(
                "local_engine.parameter_out_of_range",
                "parameter value is outside the compiled engine range"
            )
        }
        return concrete
    }

    private static func failure(_ code: String, _ message: String) -> LLMFailure {
        LLMFailure(code: code, message: message, retryable: false)
    }
}
