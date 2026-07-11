import Foundation

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

public enum CapabilityValue: Codable, Equatable, Sendable {
    case support(SupportState)
    case verifiedUpperBound(UInt64)
}

public struct CapabilityObservation: Codable, Equatable, Sendable {
    public let capabilityID: String
    public let dimension: CapabilityDimension
    public let value: CapabilityValue
    public let authority: CapabilityAuthority
    public let observedAt: Date
    public let expiresAt: Date?

    public init(
        capabilityID: String,
        dimension: CapabilityDimension,
        value: CapabilityValue,
        authority: CapabilityAuthority,
        observedAt: Date,
        expiresAt: Date?
    ) {
        self.capabilityID = capabilityID
        self.dimension = dimension
        self.value = value
        self.authority = authority
        self.observedAt = observedAt
        self.expiresAt = expiresAt
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

    public init(capabilities: [String: ResolvedCapability]) {
        self.capabilities = capabilities
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
