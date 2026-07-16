import Foundation
import LocalAgentLLMContracts

public struct ProviderPresetID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let openAI = Self(rawValue: "openai")
    public static let anthropic = Self(rawValue: "anthropic")
    public static let gemini = Self(rawValue: "gemini")
    public static let xAI = Self(rawValue: "xai")
    public static let deepSeek = Self(rawValue: "deepseek")
    public static let miniMax = Self(rawValue: "minimax")
    public static let glm = Self(rawValue: "glm")
}

public enum ProviderRetentionMode: String, Equatable, Sendable {
    case statelessRequired = "stateless_required"
    case providerStateApproved = "provider_state_approved"
}

extension ProviderRetentionMode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown provider retention mode"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ProviderAuthentication: String, Equatable, Sendable {
    case bearerAuthorization = "bearer"
    case xAPIKeyHeader = "x_api_key"
    case googleAPIKeyHeader = "google_api_key_header"
}

public enum ProviderDiscoveryStrategy: String, Equatable, Sendable {
    case providerModelList = "provider_model_list"
    case catalogAndManual = "catalog_and_manual"
}

public enum ProviderValidationStrategy: String, Equatable, Sendable {
    case accountAndModelProbe = "account_and_model_probe"
}

extension ProviderAuthentication: Codable {
    public init(from decoder: Decoder) throws {
        self = try decodeKnownRawValue(Self.self, from: decoder, subject: "provider authentication")
    }

    public func encode(to encoder: Encoder) throws { try encodeRawValue(rawValue, to: encoder) }
}

extension ProviderDiscoveryStrategy: Codable {
    public init(from decoder: Decoder) throws {
        self = try decodeKnownRawValue(Self.self, from: decoder, subject: "provider discovery strategy")
    }

    public func encode(to encoder: Encoder) throws { try encodeRawValue(rawValue, to: encoder) }
}

extension ProviderValidationStrategy: Codable {
    public init(from decoder: Decoder) throws {
        self = try decodeKnownRawValue(Self.self, from: decoder, subject: "provider validation strategy")
    }

    public func encode(to encoder: Encoder) throws { try encodeRawValue(rawValue, to: encoder) }
}

public struct ProviderPreset: Codable, Equatable, Sendable {
    public let id: ProviderPresetID
    public let displayName: String
    public let defaultBaseURL: URL
    public let authentication: ProviderAuthentication
    public let codecID: String
    public let discovery: ProviderDiscoveryStrategy
    public let validation: ProviderValidationStrategy
    public let semanticAdapterID: String

    public init(
        id: ProviderPresetID,
        displayName: String,
        defaultBaseURL: URL,
        authentication: ProviderAuthentication,
        codecID: String,
        discovery: ProviderDiscoveryStrategy,
        validation: ProviderValidationStrategy,
        semanticAdapterID: String
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.authentication = authentication
        self.codecID = codecID
        self.discovery = discovery
        self.validation = validation
        self.semanticAdapterID = semanticAdapterID
    }

    public static let shipped: [ProviderPreset] = [
        preset(.openAI, "OpenAI", "https://api.openai.com/v1", .bearerAuthorization,
               "openai_responses", .providerModelList, "openai.responses"),
        preset(.anthropic, "Anthropic", "https://api.anthropic.com/v1", .xAPIKeyHeader,
               "anthropic_messages", .providerModelList, "anthropic.messages"),
        preset(.gemini, "Gemini", "https://generativelanguage.googleapis.com/v1beta", .googleAPIKeyHeader,
               "gemini_interactions", .providerModelList, "gemini.interactions"),
        preset(.xAI, "xAI", "https://api.x.ai/v1", .bearerAuthorization,
               "openai_responses", .providerModelList, "xai.responses"),
        preset(.deepSeek, "DeepSeek", "https://api.deepseek.com", .bearerAuthorization,
               "openai_chat_completions", .providerModelList, "deepseek.chat_completions"),
        preset(.miniMax, "MiniMax", "https://api.minimax.io/anthropic/v1", .xAPIKeyHeader,
               "anthropic_messages", .providerModelList, "minimax.messages"),
        preset(.glm, "GLM", "https://open.bigmodel.cn/api/paas/v4", .bearerAuthorization,
               "openai_chat_completions", .catalogAndManual, "glm.chat_completions"),
    ]

    private static func preset(
        _ id: ProviderPresetID,
        _ displayName: String,
        _ baseURL: String,
        _ authentication: ProviderAuthentication,
        _ codecID: String,
        _ discovery: ProviderDiscoveryStrategy,
        _ semanticAdapterID: String
    ) -> ProviderPreset {
        ProviderPreset(
            id: id,
            displayName: displayName,
            defaultBaseURL: URL(string: baseURL)!,
            authentication: authentication,
            codecID: codecID,
            discovery: discovery,
            validation: .accountAndModelProbe,
            semanticAdapterID: semanticAdapterID
        )
    }
}

private func decodeKnownRawValue<Value: RawRepresentable>(
    _ type: Value.Type,
    from decoder: Decoder,
    subject: String
) throws -> Value where Value.RawValue == String {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let value = Value(rawValue: rawValue) else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "unknown \(subject)"
        )
    }
    return value
}

private func encodeRawValue(_ rawValue: String, to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
}
