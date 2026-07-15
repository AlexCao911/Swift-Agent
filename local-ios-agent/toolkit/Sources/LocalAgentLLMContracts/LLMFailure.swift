public enum LLMRecoveryAction: String, Codable, Equatable, Sendable {
    case retry
    case chooseAnotherModel = "choose_another_model"
    case freeStorage = "free_storage"
    case openSettings = "open_settings"
    case reinstallModel = "reinstall_model"
    case contactSupport = "contact_support"
}

public struct LLMFailure: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let recoveryAction: LLMRecoveryAction?
    public let redactedDiagnostics: [String: String]

    public init(
        code: String,
        message: String,
        retryable: Bool,
        recoveryAction: LLMRecoveryAction? = nil,
        redactedDiagnostics: [String: String] = [:]
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.recoveryAction = recoveryAction
        self.redactedDiagnostics = redactedDiagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case recoveryAction
        case redactedDiagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        recoveryAction = try container.decodeIfPresent(
            LLMRecoveryAction.self,
            forKey: .recoveryAction
        )
        redactedDiagnostics = try container.decodeIfPresent(
            [String: String].self,
            forKey: .redactedDiagnostics
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(retryable, forKey: .retryable)
        try container.encodeIfPresent(recoveryAction, forKey: .recoveryAction)
        try container.encode(redactedDiagnostics, forKey: .redactedDiagnostics)
    }
}
