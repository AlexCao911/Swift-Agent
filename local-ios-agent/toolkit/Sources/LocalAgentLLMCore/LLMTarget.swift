import LocalAgentLLMContracts

public enum LLMTargetKind: Codable, Equatable, Sendable {
    case local(installationID: String)
    case cloud(providerProfileID: String, providerProfileRevision: UInt64)

    private enum CodingKeys: String, CodingKey { case kind, payload }
    private enum PayloadKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installationID = "installation_id"
        case providerProfileID = "provider_profile_id"
        case providerProfileRevision = "provider_profile_revision"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        guard try payload.decode(String.self, forKey: .schemaVersion) == "1" else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: payload,
                debugDescription: "unsupported LLM target payload schema version"
            )
        }
        switch kind {
        case "local":
            let installationID = try payload.decode(String.self, forKey: .installationID)
            guard !installationID.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .installationID,
                    in: payload,
                    debugDescription: "local target installation ID is empty"
                )
            }
            self = .local(installationID: installationID)
        case "cloud":
            let profileID = try payload.decode(String.self, forKey: .providerProfileID)
            let revisionText = try payload.decode(String.self, forKey: .providerProfileRevision)
            guard !profileID.isEmpty,
                  revisionText == "0" || revisionText.first != "0",
                  let revision = UInt64(revisionText)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .providerProfileRevision,
                    in: payload,
                    debugDescription: "cloud target provider identity is invalid"
                )
            }
            self = .cloud(providerProfileID: profileID, providerProfileRevision: revision)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown LLM target kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        try payload.encode("1", forKey: .schemaVersion)
        switch self {
        case let .local(installationID):
            try container.encode("local", forKey: .kind)
            try payload.encode(installationID, forKey: .installationID)
        case let .cloud(providerProfileID, providerProfileRevision):
            try container.encode("cloud", forKey: .kind)
            try payload.encode(providerProfileID, forKey: .providerProfileID)
            try payload.encode(String(providerProfileRevision), forKey: .providerProfileRevision)
        }
    }
}

public struct LLMTargetReference: Codable, Equatable, Sendable {
    public let targetID: LLMTargetID
    public let revision: UInt64

    public init(targetID: LLMTargetID, revision: UInt64) {
        self.targetID = targetID
        self.revision = revision
    }
}

public struct LLMTargetRevision: Codable, Equatable, Sendable {
    public let targetID: LLMTargetID
    public let revision: UInt64
    public let kind: LLMTargetKind
    public let modelID: String
    public let defaultParameters: GenerationConfiguration

    public init(
        targetID: LLMTargetID,
        revision: UInt64,
        kind: LLMTargetKind,
        modelID: String,
        defaultParameters: GenerationConfiguration
    ) {
        self.targetID = targetID
        self.revision = revision
        self.kind = kind
        self.modelID = modelID
        self.defaultParameters = defaultParameters
    }

    public var reference: LLMTargetReference {
        LLMTargetReference(targetID: targetID, revision: revision)
    }
}
