import Foundation
import LocalAgentLLMContracts

public struct LocalModelRevisionID: Hashable, Codable, Sendable {
    public let modelID: String
    public let revision: UInt64

    public init(modelID: String, revision: UInt64) {
        self.modelID = modelID
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey { case modelID = "model_id", revision }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decode(String.self, forKey: .modelID)
        revision = try container.decodeUnsignedDecimal(forKey: .revision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(String(revision), forKey: .revision)
    }
}

public enum LocalModelArtifactRole: String, Codable, Sendable {
    case weights
    case tokenizer
    case multimodalProjection = "multimodal_projection"
    case chatTemplate = "chat_template"
}

public enum LocalDeviceClass: String, Codable, Sendable { case phone, tablet }
public enum LocalMemoryClass: String, Codable, Sendable { case small, medium, large }

public struct LocalModelArtifactManifest: Codable, Equatable, Sendable {
    public let artifactID: String
    public let role: LocalModelArtifactRole
    public let relativePath: String
    public let downloadURL: URL
    public let byteSize: UInt64
    public let artifactSHA256: String

    public init(
        artifactID: String,
        role: LocalModelArtifactRole,
        relativePath: String,
        downloadURL: URL,
        byteSize: UInt64,
        artifactSHA256: String
    ) {
        self.artifactID = artifactID
        self.role = role
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.byteSize = byteSize
        self.artifactSHA256 = artifactSHA256
    }

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id", role, relativePath = "relative_path"
        case downloadURL = "download_url", byteSize = "byte_size"
        case artifactSHA256 = "artifact_sha256"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifactID = try container.decode(String.self, forKey: .artifactID)
        role = try container.decode(LocalModelArtifactRole.self, forKey: .role)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        byteSize = try container.decodeUnsignedDecimal(forKey: .byteSize)
        artifactSHA256 = try container.decode(String.self, forKey: .artifactSHA256)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artifactID, forKey: .artifactID)
        try container.encode(role, forKey: .role)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encode(String(byteSize), forKey: .byteSize)
        try container.encode(artifactSHA256, forKey: .artifactSHA256)
    }
}

public struct LocalCapabilityDeclaration: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let value: CapabilityValue

    public init(capabilityID: String, value: CapabilityValue) {
        self.capabilityID = capabilityID
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case capabilityID = "capability_id", valueType = "value_type", value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilityID = try container.decode(String.self, forKey: .capabilityID)
        switch try container.decode(String.self, forKey: .valueType) {
        case "support":
            value = .support(try container.decode(SupportState.self, forKey: .value))
        case "verified_upper_bound":
            value = .verifiedUpperBound(try container.decodeUnsignedDecimal(forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .valueType,
                in: container,
                debugDescription: "unknown capability value type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capabilityID, forKey: .capabilityID)
        switch value {
        case let .support(support):
            try container.encode("support", forKey: .valueType)
            try container.encode(support, forKey: .value)
        case let .verifiedUpperBound(bound):
            try container.encode("verified_upper_bound", forKey: .valueType)
            try container.encode(String(bound), forKey: .value)
        }
    }
}

public struct LocalEngineLoadTemplate: Codable, Equatable, Sendable {
    public let contextTokens: UInt64
    public let requiredArtifactRoles: Set<LocalModelArtifactRole>
    public let manifestControlledOptions: [String: CanonicalJSONValue]

    public init(
        contextTokens: UInt64,
        requiredArtifactRoles: Set<LocalModelArtifactRole>,
        manifestControlledOptions: [String: CanonicalJSONValue]
    ) {
        self.contextTokens = contextTokens
        self.requiredArtifactRoles = requiredArtifactRoles
        self.manifestControlledOptions = manifestControlledOptions
    }

    enum CodingKeys: String, CodingKey {
        case contextTokens = "context_tokens"
        case requiredArtifactRoles = "required_artifact_roles"
        case manifestControlledOptions = "manifest_controlled_options"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextTokens = try container.decodeUnsignedDecimal(forKey: .contextTokens)
        requiredArtifactRoles = try container.decode(Set<LocalModelArtifactRole>.self, forKey: .requiredArtifactRoles)
        manifestControlledOptions = try container.decode([String: CanonicalJSONValue].self, forKey: .manifestControlledOptions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(contextTokens), forKey: .contextTokens)
        try container.encode(requiredArtifactRoles.sorted { $0.rawValue < $1.rawValue }, forKey: .requiredArtifactRoles)
        try container.encode(manifestControlledOptions, forKey: .manifestControlledOptions)
    }
}

public struct LocalChatTemplateSelector: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case gguf, catalogArtifact = "catalog_artifact" }
    public let source: Source
    public let templateID: String

    public init(source: Source, templateID: String) {
        self.source = source
        self.templateID = templateID
    }

    enum CodingKeys: String, CodingKey { case source, templateID = "template_id" }
}

public struct LocalModelRevisionManifest: Codable, Equatable, Sendable {
    public let id: LocalModelRevisionID
    public let displayName: String
    public let family: String
    public let engineID: String
    public let modelFormat: String
    public let artifacts: [LocalModelArtifactManifest]
    public let installedByteSize: UInt64
    public let minimumOSMajor: Int
    public let supportedDeviceClasses: Set<LocalDeviceClass>
    public let estimatedMemoryClass: LocalMemoryClass
    public let declaredCapabilities: [LocalCapabilityDeclaration]
    public let parameterSchema: LLMParameterSchema
    public let parameterDefaults: GenerationConfiguration
    public let loadTemplate: LocalEngineLoadTemplate
    public let chatTemplate: LocalChatTemplateSelector
    public let toolCallCodecID: String?

    public init(
        id: LocalModelRevisionID,
        displayName: String,
        family: String,
        engineID: String,
        modelFormat: String,
        artifacts: [LocalModelArtifactManifest],
        installedByteSize: UInt64,
        minimumOSMajor: Int,
        supportedDeviceClasses: Set<LocalDeviceClass>,
        estimatedMemoryClass: LocalMemoryClass,
        declaredCapabilities: [LocalCapabilityDeclaration],
        parameterSchema: LLMParameterSchema,
        parameterDefaults: GenerationConfiguration,
        loadTemplate: LocalEngineLoadTemplate,
        chatTemplate: LocalChatTemplateSelector,
        toolCallCodecID: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.engineID = engineID
        self.modelFormat = modelFormat
        self.artifacts = artifacts
        self.installedByteSize = installedByteSize
        self.minimumOSMajor = minimumOSMajor
        self.supportedDeviceClasses = supportedDeviceClasses
        self.estimatedMemoryClass = estimatedMemoryClass
        self.declaredCapabilities = declaredCapabilities
        self.parameterSchema = parameterSchema
        self.parameterDefaults = parameterDefaults
        self.loadTemplate = loadTemplate
        self.chatTemplate = chatTemplate
        self.toolCallCodecID = toolCallCodecID
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", family, engineID = "engine_id"
        case modelFormat = "model_format", artifacts
        case installedByteSize = "installed_byte_size", minimumOSMajor = "minimum_os_major"
        case supportedDeviceClasses = "supported_device_classes"
        case estimatedMemoryClass = "estimated_memory_class"
        case declaredCapabilities = "declared_capabilities"
        case parameterSchema = "parameter_schema", parameterDefaults = "parameter_defaults"
        case loadTemplate = "load_template", chatTemplate = "chat_template"
        case toolCallCodecID = "tool_call_codec_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LocalModelRevisionID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        family = try container.decode(String.self, forKey: .family)
        engineID = try container.decode(String.self, forKey: .engineID)
        modelFormat = try container.decode(String.self, forKey: .modelFormat)
        artifacts = try container.decode([LocalModelArtifactManifest].self, forKey: .artifacts)
        installedByteSize = try container.decodeUnsignedDecimal(forKey: .installedByteSize)
        minimumOSMajor = try container.decode(Int.self, forKey: .minimumOSMajor)
        supportedDeviceClasses = try container.decode(Set<LocalDeviceClass>.self, forKey: .supportedDeviceClasses)
        estimatedMemoryClass = try container.decode(LocalMemoryClass.self, forKey: .estimatedMemoryClass)
        declaredCapabilities = try container.decode([LocalCapabilityDeclaration].self, forKey: .declaredCapabilities)
        parameterSchema = try container.decode(LLMParameterSchema.self, forKey: .parameterSchema)
        parameterDefaults = try container.decode(GenerationConfiguration.self, forKey: .parameterDefaults)
        loadTemplate = try container.decode(LocalEngineLoadTemplate.self, forKey: .loadTemplate)
        chatTemplate = try container.decode(LocalChatTemplateSelector.self, forKey: .chatTemplate)
        toolCallCodecID = try container.decodeIfPresent(String.self, forKey: .toolCallCodecID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(family, forKey: .family)
        try container.encode(engineID, forKey: .engineID)
        try container.encode(modelFormat, forKey: .modelFormat)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encode(String(installedByteSize), forKey: .installedByteSize)
        try container.encode(minimumOSMajor, forKey: .minimumOSMajor)
        try container.encode(supportedDeviceClasses.sorted { $0.rawValue < $1.rawValue }, forKey: .supportedDeviceClasses)
        try container.encode(estimatedMemoryClass, forKey: .estimatedMemoryClass)
        try container.encode(declaredCapabilities, forKey: .declaredCapabilities)
        try container.encode(parameterSchema, forKey: .parameterSchema)
        try container.encode(parameterDefaults, forKey: .parameterDefaults)
        try container.encode(loadTemplate, forKey: .loadTemplate)
        try container.encode(chatTemplate, forKey: .chatTemplate)
        try container.encodeIfPresent(toolCallCodecID, forKey: .toolCallCodecID)
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeUnsignedDecimal(forKey key: Key) throws -> UInt64 {
        let raw = try decode(String.self, forKey: key)
        guard !raw.isEmpty,
              raw == "0" || raw.first != "0",
              raw.allSatisfy(\.isNumber),
              let value = UInt64(raw)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "expected canonical UInt64 decimal string"
            )
        }
        return value
    }
}
