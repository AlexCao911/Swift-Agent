public struct PreparedSessionRegistrationV1Document: Sendable {
    public let preparationID: String
    public let proposedRunID: String
    public let sessionHandle: String
    public let swiftSnapshotID: String
    public let hostProcessEpoch: String
    public let bindingID: String
    public let bindingRevision: UInt64
    public let bindingHash: String

    public init(
        preparationID: String,
        proposedRunID: String,
        sessionHandle: String,
        swiftSnapshotID: String,
        hostProcessEpoch: String,
        bindingID: String,
        bindingRevision: UInt64,
        bindingHash: String
    ) {
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.sessionHandle = sessionHandle
        self.swiftSnapshotID = swiftSnapshotID
        self.hostProcessEpoch = hostProcessEpoch
        self.bindingID = bindingID
        self.bindingRevision = bindingRevision
        self.bindingHash = bindingHash
    }

    public func computedDigest() throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(
            domain: "prepared-session-registration:v1",
            document: .object(entries: [
                .init(name: "preparation_id", value: .string(preparationID)),
                .init(name: "proposed_run_id", value: .string(proposedRunID)),
                .init(name: "session_handle", value: .string(sessionHandle)),
                .init(name: "swift_snapshot_id", value: .string(swiftSnapshotID)),
                .init(name: "host_process_epoch", value: .string(hostProcessEpoch)),
                .init(name: "binding_id", value: .string(bindingID)),
                .init(name: "binding_revision", value: .number(Double(bindingRevision))),
                .init(name: "binding_hash", value: .string(bindingHash)),
            ])
        )
    }
}

public enum LocalEgressSubjectV1 {
    public static func notApplicableDigest() throws -> CanonicalDigest {
        try CanonicalDigestV1.digest(
            domain: "egress-subject:v1",
            document: .object(entries: [
                .init(name: "kind", value: .string("not_applicable")),
                .init(name: "reason", value: .string("local_inference")),
                .init(name: "schema_version", value: .string("1")),
            ])
        )
    }
}
