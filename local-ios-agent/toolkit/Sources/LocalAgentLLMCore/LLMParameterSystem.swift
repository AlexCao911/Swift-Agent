import LocalAgentLLMContracts

public enum LLMParameterSystem {
    public static func resolve(
        modelDefaults: GenerationConfiguration = GenerationConfiguration(),
        targetDefaults: GenerationConfiguration = GenerationConfiguration(),
        hostOverrides: GenerationConfiguration = GenerationConfiguration(),
        schema: LLMParameterSchema
    ) throws -> GenerationConfiguration {
        var merged = modelDefaults.parameters
        merged.merge(targetDefaults.parameters) { _, target in target }
        merged.merge(hostOverrides.parameters) { _, host in host }

        for (rawID, value) in merged {
            let id = LLMParameterID(rawValue: rawID)
            guard let definition = schema.definition(for: id),
                  definition.support == .supported
            else {
                throw failure(
                    "llm.parameter.unsupported",
                    "unsupported semantic parameter: \(rawID)"
                )
            }
            try validate(value, against: definition)
        }

        for (rawID, _) in merged {
            let id = LLMParameterID(rawValue: rawID)
            guard let definition = schema.definition(for: id) else {
                continue
            }
            if let conflict = definition.mutuallyExclusiveWith.first(where: {
                merged[$0.rawValue] != nil
            }) {
                throw failure(
                    "llm.parameter.mutually_exclusive",
                    "\(rawID) cannot be combined with \(conflict.rawValue)"
                )
            }
            if let condition = definition.disabledWhen,
               condition.matches(parameters: merged)
            {
                throw failure(
                    "llm.parameter.conditionally_disabled",
                    "semantic parameter is disabled by the resolved configuration: \(rawID)"
                )
            }
        }

        return GenerationConfiguration(parameters: merged)
    }

    private static func validate(
        _ value: LLMParameterValue,
        against definition: LLMParameterDefinition
    ) throws {
        let numericValue: Double?
        switch (definition.valueType, value) {
        case let (.decimal, .decimal(number)):
            numericValue = number
        case let (.integer, .integer(number)):
            numericValue = Double(number)
        case let (.text, .text(choice)):
            numericValue = nil
            if !definition.choices.isEmpty && !definition.choices.contains(choice) {
                throw failure("llm.parameter.invalid_choice", "parameter choice is unsupported")
            }
        case (.boolean, .boolean), (.textList, .textList):
            numericValue = nil
        default:
            throw failure("llm.parameter.type_mismatch", "parameter value has the wrong type")
        }

        if let numericValue,
           !numericValue.isFinite
            || definition.minimum.map({ numericValue < $0 }) == true
            || definition.maximum.map({ numericValue > $0 }) == true
        {
            throw failure("llm.parameter.out_of_range", "parameter value is out of range")
        }
    }

    private static func failure(_ code: String, _ message: String) -> LLMFailure {
        LLMFailure(code: code, message: message, retryable: false)
    }
}

private extension LLMParameterCondition {
    func matches(parameters: [String: LLMParameterValue]) -> Bool {
        switch self {
        case let .equals(id, expected):
            parameters[id.rawValue] == expected
        }
    }
}
