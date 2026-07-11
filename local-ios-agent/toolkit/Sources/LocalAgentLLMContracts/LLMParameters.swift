public struct LLMParameterID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let samplingTemperature = Self(rawValue: "sampling.temperature")
    public static let samplingTopP = Self(rawValue: "sampling.top_p")
    public static let samplingTopK = Self(rawValue: "sampling.top_k")
    public static let samplingMinP = Self(rawValue: "sampling.min_p")
    public static let samplingRepetitionPenalty = Self(rawValue: "sampling.repetition_penalty")
    public static let generationMaxOutputTokens = Self(rawValue: "generation.max_output_tokens")
    public static let generationSeed = Self(rawValue: "generation.seed")
    public static let generationStopSequences = Self(rawValue: "generation.stop_sequences")
    public static let reasoningEffort = Self(rawValue: "reasoning.effort")
    public static let reasoningTokenBudget = Self(rawValue: "reasoning.token_budget")
    public static let outputVerbosity = Self(rawValue: "output.verbosity")
}

public enum LLMParameterValue: Codable, Equatable, Sendable {
    case decimal(Double)
    case integer(Int64)
    case text(String)
    case boolean(Bool)
    case textList([String])
}

public struct GenerationConfiguration: Codable, Equatable, Sendable {
    public let parameters: [String: LLMParameterValue]

    public init(parameters: [String: LLMParameterValue] = [:]) {
        self.parameters = parameters
    }

    public func setting(_ id: LLMParameterID, to value: LLMParameterValue) -> Self {
        var values = parameters
        values[id.rawValue] = value
        return Self(parameters: values)
    }

    public func value(for id: LLMParameterID) -> LLMParameterValue? {
        parameters[id.rawValue]
    }
}

public enum LLMParameterValueType: String, Codable, Equatable, Sendable {
    case decimal
    case integer
    case text
    case boolean
    case textList = "text_list"
}

public enum LLMParameterCondition: Codable, Equatable, Sendable {
    case equals(LLMParameterID, LLMParameterValue)
}

public struct LLMParameterDefinition: Codable, Equatable, Sendable {
    public let id: LLMParameterID
    public let valueType: LLMParameterValueType
    public let support: SupportState
    public let minimum: Double?
    public let maximum: Double?
    public let choices: Set<String>
    public let mutuallyExclusiveWith: Set<LLMParameterID>
    public let disabledWhen: LLMParameterCondition?

    public init(
        id: LLMParameterID,
        valueType: LLMParameterValueType,
        support: SupportState,
        minimum: Double? = nil,
        maximum: Double? = nil,
        choices: Set<String> = [],
        mutuallyExclusiveWith: Set<LLMParameterID> = [],
        disabledWhen: LLMParameterCondition? = nil
    ) {
        self.id = id
        self.valueType = valueType
        self.support = support
        self.minimum = minimum
        self.maximum = maximum
        self.choices = choices
        self.mutuallyExclusiveWith = mutuallyExclusiveWith
        self.disabledWhen = disabledWhen
    }

    public static func decimal(
        _ id: LLMParameterID,
        support: SupportState,
        minimum: Double,
        maximum: Double,
        mutuallyExclusiveWith: Set<LLMParameterID> = [],
        disabledWhen: LLMParameterCondition? = nil
    ) -> Self {
        Self(
            id: id,
            valueType: .decimal,
            support: support,
            minimum: minimum,
            maximum: maximum,
            mutuallyExclusiveWith: mutuallyExclusiveWith,
            disabledWhen: disabledWhen
        )
    }

    public static func integer(
        _ id: LLMParameterID,
        support: SupportState,
        minimum: Int64,
        maximum: Int64,
        mutuallyExclusiveWith: Set<LLMParameterID> = [],
        disabledWhen: LLMParameterCondition? = nil
    ) -> Self {
        Self(
            id: id,
            valueType: .integer,
            support: support,
            minimum: Double(minimum),
            maximum: Double(maximum),
            mutuallyExclusiveWith: mutuallyExclusiveWith,
            disabledWhen: disabledWhen
        )
    }

    public static func choice(
        _ id: LLMParameterID,
        support: SupportState,
        choices: Set<String>,
        mutuallyExclusiveWith: Set<LLMParameterID> = [],
        disabledWhen: LLMParameterCondition? = nil
    ) -> Self {
        Self(
            id: id,
            valueType: .text,
            support: support,
            choices: choices,
            mutuallyExclusiveWith: mutuallyExclusiveWith,
            disabledWhen: disabledWhen
        )
    }
}

public struct LLMParameterSchema: Codable, Equatable, Sendable {
    public let definitions: [String: LLMParameterDefinition]

    public init(definitions: [LLMParameterDefinition]) {
        self.definitions = Dictionary(
            definitions.map { ($0.id.rawValue, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func definition(for id: LLMParameterID) -> LLMParameterDefinition? {
        definitions[id.rawValue]
    }
}
