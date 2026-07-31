public enum ProviderProductType: Equatable, Hashable, Sendable {
    case openAI
    case openAIResponses
    case anthropic
    case gemini
    case openRouter
    case xAI
    case kimiCode
    case antigravity
    case unsupported(String)

    public init(rawValue: String) {
        self = switch rawValue {
        case "openAI": .openAI
        case "openAIResponses": .openAIResponses
        case "anthropic": .anthropic
        case "gemini": .gemini
        case "openRouter": .openRouter
        case "xAI": .xAI
        case "kimiCode": .kimiCode
        case "antigravity": .antigravity
        default: .unsupported(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .openAI: "openAI"
        case .openAIResponses: "openAIResponses"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        case .openRouter: "openRouter"
        case .xAI: "xAI"
        case .kimiCode: "kimiCode"
        case .antigravity: "antigravity"
        case .unsupported(let rawValue): rawValue
        }
    }
}

extension ProviderProductType: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ProviderCodecFamily: String, Codable, Equatable, Sendable {
    case openAIChatCompletions = "openai_chat_completions"
    case openAIResponses = "openai_responses"
    case anthropicMessages = "anthropic_messages"
    case geminiInteractions = "gemini_interactions"
    case antigravityCloudCode = "antigravity_cloud_code"
    case unsupported
}

public enum ProviderCredentialMode: String, Codable, Equatable, Sendable {
    case apiKey = "api_key"
    case oauth
}

public struct ProviderProductMapping: Equatable, Sendable {
    public let productType: ProviderProductType
    public let presetID: ProviderPresetID?
    public let codecFamily: ProviderCodecFamily
    public let credentialModes: Set<ProviderCredentialMode>
    public let isGenerationSupported: Bool
    public let requiresDedicatedCodec: Bool
}

public enum ProviderProductCompatibility {
    public static func mapping(
        rawProviderType: String
    ) -> ProviderProductMapping {
        let type = ProviderProductType(rawValue: rawProviderType)
        return switch type {
        case .openAI:
            mapping(
                type,
                presetID: .openAIChatCompletions,
                codec: .openAIChatCompletions,
                modes: [.apiKey]
            )
        case .openAIResponses:
            mapping(
                type,
                presetID: .openAI,
                codec: .openAIResponses,
                modes: [.apiKey, .oauth]
            )
        case .anthropic:
            mapping(
                type,
                presetID: .anthropic,
                codec: .anthropicMessages,
                modes: [.apiKey, .oauth]
            )
        case .gemini:
            mapping(
                type,
                presetID: .gemini,
                codec: .geminiInteractions,
                modes: [.apiKey, .oauth]
            )
        case .openRouter:
            mapping(
                type,
                presetID: .openRouter,
                codec: .openAIChatCompletions,
                modes: [.apiKey]
            )
        case .xAI:
            mapping(
                type,
                presetID: .xAI,
                codec: .openAIResponses,
                modes: [.apiKey, .oauth]
            )
        case .kimiCode:
            mapping(
                type,
                presetID: .kimiCode,
                codec: .openAIChatCompletions,
                modes: [.oauth]
            )
        case .antigravity:
            mapping(
                type,
                presetID: .antigravity,
                codec: .antigravityCloudCode,
                modes: [.oauth]
            )
        case .unsupported:
            ProviderProductMapping(
                productType: type,
                presetID: nil,
                codecFamily: .unsupported,
                credentialModes: [],
                isGenerationSupported: false,
                requiresDedicatedCodec: false
            )
        }
    }

    private static func mapping(
        _ type: ProviderProductType,
        presetID: ProviderPresetID,
        codec: ProviderCodecFamily,
        modes: Set<ProviderCredentialMode>
    ) -> ProviderProductMapping {
        ProviderProductMapping(
            productType: type,
            presetID: presetID,
            codecFamily: codec,
            credentialModes: modes,
            isGenerationSupported: true,
            requiresDedicatedCodec: false
        )
    }
}
