import Foundation
import LocalAgentLLMCore

public struct ProviderProfileRevision: Codable, Equatable, Sendable {
    public let profileID: String
    public let revision: UInt64
    public let presetID: ProviderPresetID
    public let displayName: String
    public let baseURL: URL
    public let credentialRef: String
    public let retentionMode: ProviderRetentionMode
    public let credentialMode: ProviderCredentialMode?

    public init(
        profileID: String,
        revision: UInt64,
        presetID: ProviderPresetID,
        displayName: String,
        baseURL: URL,
        credentialRef: String,
        retentionMode: ProviderRetentionMode = .statelessRequired,
        credentialMode: ProviderCredentialMode? = nil
    ) {
        self.profileID = profileID
        self.revision = revision
        self.presetID = presetID
        self.displayName = displayName
        self.baseURL = baseURL
        self.credentialRef = credentialRef
        self.retentionMode = retentionMode
        self.credentialMode = credentialMode
    }
}

public struct EgressOrigin: Codable, Equatable, Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: UInt16

    public init(scheme: String, host: String, port: UInt16) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    package var serialized: String {
        "\(scheme)://\(host):\(port)"
    }
}

public enum ProviderRevisionLifecycle: String, Equatable, Sendable {
    case active
    case archived
}

extension ProviderRevisionLifecycle: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown provider revision lifecycle"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PublishedProviderProfileRevision: Codable, Equatable, Sendable {
    public let revision: ProviderProfileRevision
    public let origin: EgressOrigin
    public let lifecycle: ProviderRevisionLifecycle

    public init(
        revision: ProviderProfileRevision,
        origin: EgressOrigin,
        lifecycle: ProviderRevisionLifecycle
    ) {
        self.revision = revision
        self.origin = origin
        self.lifecycle = lifecycle
    }
}

public struct ProviderValidationEvidenceIdentity: Codable, Equatable, Sendable {
    public let modelID: String
    public let origin: EgressOrigin
    public let credentialGeneration: UInt64
    public let retentionMode: ProviderRetentionMode
    public let retentionApprovalRevision: UInt64?
    public let retentionApprovalDigest: String?
    public let catalogRevision: UInt64?
    public let adapterID: String
    public let adapterVersion: String
    public let evidenceDigest: String
    public let expiresAt: Date

    public init(
        modelID: String,
        origin: EgressOrigin,
        credentialGeneration: UInt64,
        retentionMode: ProviderRetentionMode,
        retentionApprovalRevision: UInt64?,
        retentionApprovalDigest: String?,
        catalogRevision: UInt64?,
        adapterID: String,
        adapterVersion: String,
        evidenceDigest: String,
        expiresAt: Date
    ) {
        self.modelID = modelID
        self.origin = origin
        self.credentialGeneration = credentialGeneration
        self.retentionMode = retentionMode
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.catalogRevision = catalogRevision
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.evidenceDigest = evidenceDigest
        self.expiresAt = expiresAt
    }
}

public enum ProviderProfileValidationState: Equatable, Sendable {
    case unvalidated
    case validated(ProviderValidationEvidenceIdentity)
    case invalidated(reasonCode: String)
}

extension ProviderProfileValidationState: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case evidence
        case reasonCode = "reason_code"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .tag) {
        case "unvalidated":
            self = .unvalidated
        case "validated":
            self = .validated(try container.decode(
                ProviderValidationEvidenceIdentity.self,
                forKey: .evidence
            ))
        case "invalidated":
            let reason = try container.decode(String.self, forKey: .reasonCode)
            guard !reason.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .reasonCode,
                    in: container,
                    debugDescription: "provider validation invalidation reason is empty"
                )
            }
            self = .invalidated(reasonCode: reason)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "unknown provider validation-state tag"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unvalidated:
            try container.encode("unvalidated", forKey: .tag)
        case let .validated(evidence):
            try container.encode("validated", forKey: .tag)
            try container.encode(evidence, forKey: .evidence)
        case let .invalidated(reasonCode):
            try container.encode("invalidated", forKey: .tag)
            try container.encode(reasonCode, forKey: .reasonCode)
        }
    }
}

public struct ProviderProfileState: Codable, Equatable, Sendable {
    public let profileID: String
    public let profileRevision: UInt64
    public var validationState: ProviderProfileValidationState
    public var approvedEgressOrigin: EgressOrigin?
    public var retentionApprovalRevision: UInt64?
    public var retentionApprovalDigest: String?
    public var catalogRevision: UInt64?
    public var stateRevision: UInt64

    public init(
        profileID: String,
        profileRevision: UInt64,
        validationState: ProviderProfileValidationState = .unvalidated,
        approvedEgressOrigin: EgressOrigin? = nil,
        retentionApprovalRevision: UInt64? = nil,
        retentionApprovalDigest: String? = nil,
        catalogRevision: UInt64? = nil,
        stateRevision: UInt64 = 1
    ) {
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.validationState = validationState
        self.approvedEgressOrigin = approvedEgressOrigin
        self.retentionApprovalRevision = retentionApprovalRevision
        self.retentionApprovalDigest = retentionApprovalDigest
        self.catalogRevision = catalogRevision
        self.stateRevision = stateRevision
    }
}

public struct ProviderProfileFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

package protocol ProviderOriginValidating: Sendable {
    func validate(_ baseURL: URL) async throws -> EgressOrigin
}
