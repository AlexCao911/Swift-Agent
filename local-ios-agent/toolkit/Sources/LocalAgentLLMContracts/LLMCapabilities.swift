import Foundation

public struct LLMTargetID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SupportState: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

public enum CapabilityDimension: String, Codable, Equatable, Sendable {
    case adapterCanEncode = "adapter_can_encode"
    case engineCanExecute = "engine_can_execute"
    case endpointSupports = "endpoint_supports"
    case modelSupports = "model_supports"
    case availabilityValidated = "availability_validated"
}

public enum CapabilityAuthority: String, Codable, Equatable, Sendable {
    case authoritative
    case verified
    case advisory
}

public enum CapabilitySource: String, Codable, Equatable, Sendable {
    case providerNeutral = "provider_neutral"
    case signedLocalCatalog = "signed_local_catalog"
    case compiledLocalEngine = "compiled_local_engine"
    case shippedCloudAdapter = "shipped_cloud_adapter"
    case signedCloudCatalog = "signed_cloud_catalog"
    case providerModelList = "provider_model_list"
    case connectivityProbe = "connectivity_probe"
}

public enum ValidationScope: String, Codable, Equatable, Sendable {
    case notApplicable = "not_applicable"
    case signedDeclaration = "signed_declaration"
    case compiledDescriptor = "compiled_descriptor"
    case authenticatedEndpoint = "authenticated_endpoint"
    case featureProbe = "feature_probe"
}

public enum CapabilityInvalidationTrigger: String, Codable, Equatable, Hashable, Sendable {
    case catalogRevision = "catalog_revision"
    case adapterVersion = "adapter_version"
    case engineVersion = "engine_version"
    case appBuild = "app_build"
    case osCapabilities = "os_capabilities"
    case providerProfileRevision = "provider_profile_revision"
    case credentialGeneration = "credential_generation"
    case modelIdentity = "model_identity"
}

public struct CapabilitySubject: Codable, Equatable, Sendable {
    public let adapterID: String?
    public let engineID: String?
    public let providerProfileID: String?
    public let providerProfileRevision: UInt64?
    public let credentialGeneration: UInt64?
    public let llmTargetID: LLMTargetID?
    public let llmTargetRevision: UInt64?
    public let modelID: String?
    public let modelRevision: String?
    public let catalogRevision: UInt64?

    public init(
        adapterID: String? = nil,
        engineID: String? = nil,
        providerProfileID: String? = nil,
        providerProfileRevision: UInt64? = nil,
        credentialGeneration: UInt64? = nil,
        llmTargetID: LLMTargetID? = nil,
        llmTargetRevision: UInt64? = nil,
        modelID: String? = nil,
        modelRevision: String? = nil,
        catalogRevision: UInt64? = nil
    ) {
        self.adapterID = adapterID
        self.engineID = engineID
        self.providerProfileID = providerProfileID
        self.providerProfileRevision = providerProfileRevision
        self.credentialGeneration = credentialGeneration
        self.llmTargetID = llmTargetID
        self.llmTargetRevision = llmTargetRevision
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.catalogRevision = catalogRevision
    }

    public static let unscoped = Self()

    public func encompasses(_ exact: Self) -> Bool {
        matches(adapterID, exact.adapterID)
            && matches(engineID, exact.engineID)
            && matches(providerProfileID, exact.providerProfileID)
            && matches(providerProfileRevision, exact.providerProfileRevision)
            && matches(credentialGeneration, exact.credentialGeneration)
            && matches(llmTargetID, exact.llmTargetID)
            && matches(llmTargetRevision, exact.llmTargetRevision)
            && matches(modelID, exact.modelID)
            && matches(modelRevision, exact.modelRevision)
            && matches(catalogRevision, exact.catalogRevision)
    }
}

private func matches<T: Equatable>(_ observed: T?, _ exact: T?) -> Bool {
    observed.map { $0 == exact } ?? true
}

public enum CapabilityValue: Codable, Equatable, Sendable {
    case support(SupportState)
    case verifiedUpperBound(UInt64)
}

public struct CapabilityObservation: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let dimension: CapabilityDimension
    public let value: CapabilityValue
    public let authority: CapabilityAuthority
    public let source: CapabilitySource
    public let subject: CapabilitySubject
    public let adapterOrEngineVersion: String?
    public let observedAt: Date
    public let expiresAt: Date?
    public let validationScope: ValidationScope
    public let invalidationTriggers: Set<CapabilityInvalidationTrigger>
    public let evidenceDigest: String
    public let observationDigest: String

    public init(
        capabilityID: String,
        dimension: CapabilityDimension,
        value: CapabilityValue,
        authority: CapabilityAuthority,
        source: CapabilitySource = .providerNeutral,
        subject: CapabilitySubject = .unscoped,
        adapterOrEngineVersion: String? = nil,
        observedAt: Date,
        expiresAt: Date?,
        validationScope: ValidationScope = .notApplicable,
        invalidationTriggers: Set<CapabilityInvalidationTrigger> = [],
        evidenceDigest: String = "",
        observationDigest: String = ""
    ) {
        self.capabilityID = capabilityID
        self.dimension = dimension
        self.value = value
        self.authority = authority
        self.source = source
        self.subject = subject
        self.adapterOrEngineVersion = adapterOrEngineVersion
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.validationScope = validationScope
        self.invalidationTriggers = invalidationTriggers
        self.evidenceDigest = evidenceDigest
        self.observationDigest = observationDigest
    }
}

public struct CapabilityRequirement: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let minimumVerifiedUpperBound: UInt64?

    public init(capabilityID: String, minimumVerifiedUpperBound: UInt64? = nil) {
        self.capabilityID = capabilityID
        self.minimumVerifiedUpperBound = minimumVerifiedUpperBound
    }
}

public struct ResolvedCapability: Codable, Equatable, Sendable {
    public let support: SupportState
    public let verifiedUpperBound: UInt64?

    public init(support: SupportState, verifiedUpperBound: UInt64?) {
        self.support = support
        self.verifiedUpperBound = verifiedUpperBound
    }
}

public struct CapabilitySnapshot: Codable, Equatable, Sendable {
    public let capabilities: [String: ResolvedCapability]
    public let subject: CapabilitySubject
    public let contributingObservationDigests: [String]
    public let nearestExpiry: Date?

    public init(capabilities: [String: ResolvedCapability]) {
        self.init(
            capabilities: capabilities,
            subject: .unscoped,
            contributingObservationDigests: [],
            nearestExpiry: nil
        )
    }

    public init(
        capabilities: [String: ResolvedCapability],
        subject: CapabilitySubject,
        contributingObservationDigests: [String],
        nearestExpiry: Date?
    ) {
        self.capabilities = capabilities
        self.subject = subject
        self.contributingObservationDigests = Array(Set(contributingObservationDigests)).sorted()
        self.nearestExpiry = nearestExpiry
    }

    public func support(for capabilityID: String) -> SupportState {
        capabilities[capabilityID]?.support ?? .unknown
    }

    public func verifiedUpperBound(for capabilityID: String) -> UInt64? {
        capabilities[capabilityID]?.verifiedUpperBound
    }

    public func satisfies(_ requirement: CapabilityRequirement) -> Bool {
        guard support(for: requirement.capabilityID) == .supported else {
            return false
        }
        guard let minimum = requirement.minimumVerifiedUpperBound else {
            return true
        }
        return verifiedUpperBound(for: requirement.capabilityID)
            .map { $0 >= minimum } ?? false
    }
}
