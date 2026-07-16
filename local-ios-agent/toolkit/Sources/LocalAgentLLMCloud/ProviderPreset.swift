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

public enum ProviderRetentionMode: String, Codable, Equatable, Sendable {
    case statelessRequired = "stateless_required"
    case providerStateApproved = "provider_state_approved"
}
