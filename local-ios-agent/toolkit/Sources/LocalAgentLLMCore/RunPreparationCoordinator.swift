import LocalAgentLLMContracts

public struct SwiftRunPreparationPreview: Codable, Equatable, Sendable {
    public let preparationID: String
    public let proposedRunID: String
    public let token: String
    public let bindingDigest: String
    public let hostProcessEpoch: String
    public let expirationMillis: UInt64

    public init(preparationID: String, proposedRunID: String, token: String, bindingDigest: String,
                hostProcessEpoch: String, expirationMillis: UInt64) {
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.token = token
        self.bindingDigest = bindingDigest
        self.hostProcessEpoch = hostProcessEpoch
        self.expirationMillis = expirationMillis
    }
}

public struct SwiftRunPreparationRequest: Codable, Equatable, Sendable {
    public let preview: SwiftRunPreparationPreview
    public let configuration: AgentHostConfiguration

    public init(preview: SwiftRunPreparationPreview, configuration: AgentHostConfiguration) {
        self.preview = preview
        self.configuration = configuration
    }
}

public enum PreparedResourceState: String, Codable, Equatable, Sendable {
    case allocatedNotOpened = "allocated_not_opened"
}

public struct SwiftPreparedSession: Codable, Equatable, Sendable {
    public let preparationID: String
    public let proposedRunID: String
    public let sessionHandle: String
    public let swiftSnapshotID: String
    public let hostProcessEpoch: String
    public let bindingID: String
    public let bindingRevision: UInt64
    public let bindingHash: String
    public let registrationDigest: String
    public let resourceState: PreparedResourceState
}

public struct SwiftPreparedSessionCleanupEnvelope: Codable, Equatable, Sendable {
    public let cleanupCommandID: String
    public let preparationID: String
    public let proposedRunID: String
    public let sessionHandle: String
    public let hostProcessEpoch: String
    public let cleanupSequence: UInt64
    public let registrationDigest: String
    public let cleanupCommandDigest: String

    public init(cleanupCommandID: String, preparationID: String, proposedRunID: String,
                sessionHandle: String, hostProcessEpoch: String, cleanupSequence: UInt64,
                registrationDigest: String, cleanupCommandDigest: String) {
        self.cleanupCommandID = cleanupCommandID
        self.preparationID = preparationID
        self.proposedRunID = proposedRunID
        self.sessionHandle = sessionHandle
        self.hostProcessEpoch = hostProcessEpoch
        self.cleanupSequence = cleanupSequence
        self.registrationDigest = registrationDigest
        self.cleanupCommandDigest = cleanupCommandDigest
    }
}

public struct SwiftPreparedSessionCleanupAcknowledgement: Codable, Equatable, Sendable {
    public let cleanupCommandID: String
    public let preparationID: String
    public let cleanupSequence: UInt64
    public let cleanupCommandDigest: String

    public static func from(
        _ cleanup: SwiftPreparedSessionCleanupEnvelope
    ) -> SwiftPreparedSessionCleanupAcknowledgement {
        SwiftPreparedSessionCleanupAcknowledgement(
            cleanupCommandID: cleanup.cleanupCommandID,
            preparationID: cleanup.preparationID,
            cleanupSequence: cleanup.cleanupSequence,
            cleanupCommandDigest: cleanup.cleanupCommandDigest
        )
    }
}

public enum PreparedSessionCloseDisposition: String, Codable, Equatable, Sendable {
    case closed
    case alreadyClosed = "already_closed"
}

public struct SwiftPreparedSessionClosedReceipt: Codable, Equatable, Sendable {
    public let cleanupCommandID: String
    public let preparationID: String
    public let proposedRunID: String
    public let sessionHandle: String
    public let hostProcessEpoch: String
    public let cleanupSequence: UInt64
    public let closeDisposition: PreparedSessionCloseDisposition
    public let receiptDigest: String
}

public struct RunPreparationCoordinatorError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
}

public struct RunPreparationCoordinator: Sendable {
    private let store: LLMStore

    public init(store: LLMStore) { self.store = store }

    public func prepare(_ request: SwiftRunPreparationRequest) async throws -> SwiftPreparedSession {
        let bindingHash = try agentHostConfigurationDigest(request.configuration)
        let sessionHandle = "prepared:\(request.preview.preparationID)"
        let snapshotID = "swift-snapshot:\(request.preview.preparationID)"
        let registrationDigest = try digestRegistration(
            preview: request.preview,
            sessionHandle: sessionHandle,
            snapshotID: snapshotID,
            bindingID: request.configuration.bindingID,
            bindingRevision: request.configuration.revision,
            bindingHash: bindingHash
        )
        let session = SwiftPreparedSession(
            preparationID: request.preview.preparationID,
            proposedRunID: request.preview.proposedRunID,
            sessionHandle: sessionHandle,
            swiftSnapshotID: snapshotID,
            hostProcessEpoch: request.preview.hostProcessEpoch,
            bindingID: request.configuration.bindingID,
            bindingRevision: request.configuration.revision,
            bindingHash: bindingHash,
            registrationDigest: registrationDigest,
            resourceState: .allocatedNotOpened
        )
        return try await store.prepareSession(
            StoredPreparedSessionRecord(
                request: request,
                session: session,
                state: .prepared,
                cleanup: nil,
                cleanupAcknowledgement: nil,
                closeReceipt: nil
            )
        )
    }

    public func closePreparedSession(
        _ cleanup: SwiftPreparedSessionCleanupEnvelope
    ) async throws -> SwiftPreparedSessionClosedReceipt {
        try await store.closePreparedSession(cleanup)
    }

    public func acknowledgePreparedSessionCleanup(
        _ cleanup: SwiftPreparedSessionCleanupEnvelope
    ) async throws -> SwiftPreparedSessionCleanupAcknowledgement {
        try await store.acknowledgePreparedSessionCleanup(cleanup)
    }
}

private func digestRegistration(
    preview: SwiftRunPreparationPreview,
    sessionHandle: String,
    snapshotID: String,
    bindingID: String,
    bindingRevision: UInt64,
    bindingHash: String
) throws -> String {
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "preparation_id", value: .string(preview.preparationID)),
        .init(name: "proposed_run_id", value: .string(preview.proposedRunID)),
        .init(name: "session_handle", value: .string(sessionHandle)),
        .init(name: "swift_snapshot_id", value: .string(snapshotID)),
        .init(name: "host_process_epoch", value: .string(preview.hostProcessEpoch)),
        .init(name: "binding_id", value: .string(bindingID)),
        .init(name: "binding_revision", value: .number(Double(bindingRevision))),
        .init(name: "binding_hash", value: .string(bindingHash)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "prepared-session-registration:v1",
        document: document
    ).hex
}

func digestPreparedClose(
    _ cleanup: SwiftPreparedSessionCleanupEnvelope,
    disposition: PreparedSessionCloseDisposition
) throws -> String {
    let document = try CanonicalJSONValue.object(entries: [
        .init(name: "cleanup_command_id", value: .string(cleanup.cleanupCommandID)),
        .init(name: "preparation_id", value: .string(cleanup.preparationID)),
        .init(name: "proposed_run_id", value: .string(cleanup.proposedRunID)),
        .init(name: "session_handle", value: .string(cleanup.sessionHandle)),
        .init(name: "host_process_epoch", value: .string(cleanup.hostProcessEpoch)),
        .init(name: "cleanup_sequence", value: .number(Double(cleanup.cleanupSequence))),
        .init(name: "prepared_session_registration_digest", value: .string(cleanup.registrationDigest)),
        .init(name: "cleanup_command_digest", value: .string(cleanup.cleanupCommandDigest)),
        .init(name: "close_disposition", value: .string(disposition.rawValue)),
    ])
    return try CanonicalDigestV1.digest(
        domain: "prepared-session-closed-receipt:v1",
        document: document
    ).hex
}
