import Foundation

public struct HostAttestationV1Error: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct HostAttestationV1Document: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let preparationID: String
    public let proposedRunID: String
    public let sessionID: String
    public let swiftSnapshotID: String
    public let preparedSessionRegistrationDigest: String
    public let bindingID: String
    public let bindingRevision: String
    public let bindingHash: String
    public let requirementsHash: String
    public let disclosureDigest: String
    public let capabilitySnapshotDigest: String
    public let resolvedParametersDigest: String
    public let hostProcessEpoch: String
    public let expiresAt: String
    public let opaqueEgressSubjectDigest: String

    public init(
        schemaVersion: String = "1",
        preparationID: String,
        proposedRunID: String,
        sessionID: String,
        swiftSnapshotID: String,
        preparedSessionRegistrationDigest: String,
        bindingID: String,
        bindingRevision: String,
        bindingHash: String,
        requirementsHash: String,
        disclosureDigest: String,
        capabilitySnapshotDigest: String,
        resolvedParametersDigest: String,
        hostProcessEpoch: String,
        expiresAt: String,
        opaqueEgressSubjectDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.sessionID = sessionID
        self.swiftSnapshotID = swiftSnapshotID
        self.preparedSessionRegistrationDigest = preparedSessionRegistrationDigest
        self.bindingID = bindingID
        self.bindingRevision = bindingRevision
        self.bindingHash = bindingHash
        self.requirementsHash = requirementsHash
        self.disclosureDigest = disclosureDigest
        self.capabilitySnapshotDigest = capabilitySnapshotDigest
        self.resolvedParametersDigest = resolvedParametersDigest
        self.hostProcessEpoch = hostProcessEpoch
        self.expiresAt = expiresAt
        self.opaqueEgressSubjectDigest = opaqueEgressSubjectDigest
    }

    public func computedDigest() throws -> CanonicalDigest {
        try validate()
        return try CanonicalDigestV1.digest(
            domain: "egress-attestation:v1",
            document: canonicalDocument()
        )
    }

    public func replacing(expiresAt: String) -> Self {
        Self(
            schemaVersion: schemaVersion,
            preparationID: preparationID,
            proposedRunID: proposedRunID,
            sessionID: sessionID,
            swiftSnapshotID: swiftSnapshotID,
            preparedSessionRegistrationDigest: preparedSessionRegistrationDigest,
            bindingID: bindingID,
            bindingRevision: bindingRevision,
            bindingHash: bindingHash,
            requirementsHash: requirementsHash,
            disclosureDigest: disclosureDigest,
            capabilitySnapshotDigest: capabilitySnapshotDigest,
            resolvedParametersDigest: resolvedParametersDigest,
            hostProcessEpoch: hostProcessEpoch,
            expiresAt: expiresAt,
            opaqueEgressSubjectDigest: opaqueEgressSubjectDigest
        )
    }

    private func validate() throws {
        guard schemaVersion == "1",
              !preparationID.isEmpty,
              !proposedRunID.isEmpty,
              !sessionID.isEmpty,
              !swiftSnapshotID.isEmpty,
              !bindingID.isEmpty,
              UInt64(bindingRevision).map(String.init) == bindingRevision,
              !hostProcessEpoch.isEmpty
        else {
            throw invalid("host attestation identity or schema is not canonical")
        }
        for digest in [
            preparedSessionRegistrationDigest, bindingHash, requirementsHash,
            disclosureDigest, capabilitySnapshotDigest, resolvedParametersDigest,
            opaqueEgressSubjectDigest,
        ] where !isLowercaseSHA256(digest) {
            throw invalid("host attestation digests must be lowercase SHA-256")
        }
        guard Self.timestampFormatter.date(from: expiresAt) != nil,
              Self.timestampFormatter.string(from: Self.timestampFormatter.date(from: expiresAt)!) == expiresAt
        else {
            throw invalid("host attestation expiry must use canonical UTC milliseconds")
        }
    }

    private func canonicalDocument() throws -> CanonicalJSONValue {
        try .object(entries: [
            .init(name: "schema_version", value: .string(schemaVersion)),
            .init(name: "preparation_id", value: .string(preparationID)),
            .init(name: "proposed_run_id", value: .string(proposedRunID)),
            .init(name: "session_id", value: .string(sessionID)),
            .init(name: "swift_snapshot_id", value: .string(swiftSnapshotID)),
            .init(name: "prepared_session_registration_digest", value: .string(preparedSessionRegistrationDigest)),
            .init(name: "binding_id", value: .string(bindingID)),
            .init(name: "binding_revision", value: .string(bindingRevision)),
            .init(name: "binding_hash", value: .string(bindingHash)),
            .init(name: "requirements_hash", value: .string(requirementsHash)),
            .init(name: "disclosure_digest", value: .string(disclosureDigest)),
            .init(name: "capability_snapshot_digest", value: .string(capabilitySnapshotDigest)),
            .init(name: "resolved_parameters_digest", value: .string(resolvedParametersDigest)),
            .init(name: "host_process_epoch", value: .string(hostProcessEpoch)),
            .init(name: "expires_at", value: .string(expiresAt)),
            .init(name: "opaque_egress_subject_digest", value: .string(opaqueEgressSubjectDigest)),
        ])
    }

    private func invalid(_ message: String) -> HostAttestationV1Error {
        HostAttestationV1Error(code: "host_attestation.invalid", message: message)
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case preparationID = "preparation_id"
        case proposedRunID = "proposed_run_id"
        case sessionID = "session_id"
        case swiftSnapshotID = "swift_snapshot_id"
        case preparedSessionRegistrationDigest = "prepared_session_registration_digest"
        case bindingID = "binding_id"
        case bindingRevision = "binding_revision"
        case bindingHash = "binding_hash"
        case requirementsHash = "requirements_hash"
        case disclosureDigest = "disclosure_digest"
        case capabilitySnapshotDigest = "capability_snapshot_digest"
        case resolvedParametersDigest = "resolved_parameters_digest"
        case hostProcessEpoch = "host_process_epoch"
        case expiresAt = "expires_at"
        case opaqueEgressSubjectDigest = "opaque_egress_subject_digest"
    }
}
