import Foundation

public enum StoredHostBindingState: String, Codable, Equatable, Sendable {
    case staged
    case active
}

struct StoredHostBindingRecord: Codable, Equatable, Sendable {
    let request: HostBindingStageRequest
    let receipt: HostBindingStagingReceipt
    var state: StoredHostBindingState
}

public enum StoredPreparedSessionState: String, Codable, Equatable, Sendable {
    case prepared
    case closed
}

struct StoredPreparedSessionRecord: Codable, Equatable, Sendable {
    let request: SwiftRunPreparationRequest
    let session: SwiftPreparedSession
    var state: StoredPreparedSessionState
    var cleanup: SwiftPreparedSessionCleanupEnvelope?
    var cleanupAcknowledgement: SwiftPreparedSessionCleanupAcknowledgement?
    var closeReceipt: SwiftPreparedSessionClosedReceipt?
}

private struct LLMStoreDocument: Codable, Equatable, Sendable {
    var schemaVersion: UInt64 = 1
    var hostBindings: [String: StoredHostBindingRecord] = [:]
    var preparedSessions: [String: StoredPreparedSessionRecord] = [:]

    enum CodingKeys: String, CodingKey { case schemaVersion, hostBindings, preparedSessions }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(UInt64.self, forKey: .schemaVersion) ?? 1
        hostBindings = try container.decodeIfPresent([String: StoredHostBindingRecord].self, forKey: .hostBindings) ?? [:]
        preparedSessions = try container.decodeIfPresent([String: StoredPreparedSessionRecord].self, forKey: .preparedSessions) ?? [:]
    }
}

public actor LLMStore {
    private let fileURL: URL?
    private var document: LLMStoreDocument
    private var injectedPersistenceFailure = false

    public static func inMemory() -> LLMStore {
        try! LLMStore(fileURL: nil)
    }

    public init(fileURL: URL) throws {
        try self.init(fileURL: Optional(fileURL))
    }

    private init(fileURL: URL?) throws {
        self.fileURL = fileURL
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            document = try JSONDecoder().decode(LLMStoreDocument.self, from: data)
        } else {
            document = LLMStoreDocument()
        }
    }

    func stage(_ record: StoredHostBindingRecord) throws -> HostBindingStagingReceipt {
        let token = record.request.operationToken
        if let existing = document.hostBindings[token] {
            guard existing.request == record.request, existing.receipt == record.receipt else {
                throw HostBindingSagaError(
                    code: "host_binding.idempotency_conflict",
                    message: "operation token was replayed with different staging input"
                )
            }
            return existing.receipt
        }
        let previous = document
        document.hostBindings[token] = record
        do {
            try persist()
        } catch {
            document = previous
            throw error
        }
        return record.receipt
    }

    func activate(token: String, binding: HostBindingTuple) throws {
        guard var record = document.hostBindings[token] else {
            throw HostBindingSagaError(
                code: "host_binding.staged_binding_not_found",
                message: "no staged host binding exists for the operation token"
            )
        }
        guard record.receipt.binding == binding else {
            throw HostBindingSagaError(
                code: "host_binding.binding_mismatch",
                message: "activation tuple differs from the staged binding tuple"
            )
        }
        if record.state == .active { return }
        let previous = document
        record.state = .active
        document.hostBindings[token] = record
        do {
            try persist()
        } catch {
            document = previous
            throw error
        }
    }

    func record(token: String) -> StoredHostBindingRecord? {
        document.hostBindings[token]
    }

    public func bindingState(token: String) -> StoredHostBindingState? {
        document.hostBindings[token]?.state
    }

    func prepareSession(_ record: StoredPreparedSessionRecord) throws -> SwiftPreparedSession {
        let id = record.session.preparationID
        if let existing = document.preparedSessions[id] {
            guard existing.request == record.request, existing.session == record.session else {
                throw RunPreparationCoordinatorError(
                    code: "preparation.idempotency_conflict",
                    message: "preparation was replayed with a different Swift snapshot"
                )
            }
            return existing.session
        }
        let previous = document
        document.preparedSessions[id] = record
        do { try persist() } catch { document = previous; throw error }
        return record.session
    }

    func closePreparedSession(
        _ cleanup: SwiftPreparedSessionCleanupEnvelope
    ) throws -> SwiftPreparedSessionClosedReceipt {
        guard var record = document.preparedSessions[cleanup.preparationID] else {
            throw cleanupMismatch()
        }
        let exact = cleanup.proposedRunID == record.session.proposedRunID
            && cleanup.sessionHandle == record.session.sessionHandle
            && cleanup.hostProcessEpoch == record.session.hostProcessEpoch
            && cleanup.registrationDigest == record.session.registrationDigest
        guard exact else { throw cleanupMismatch() }
        guard record.cleanup == cleanup,
              record.cleanupAcknowledgement == SwiftPreparedSessionCleanupAcknowledgement.from(cleanup)
        else { throw cleanupNotAcknowledged() }
        if record.state == .closed {
            guard record.cleanup == cleanup, let receipt = record.closeReceipt else {
                throw cleanupMismatch()
            }
            return receipt
        }
        let receipt = SwiftPreparedSessionClosedReceipt(
            cleanupCommandID: cleanup.cleanupCommandID,
            preparationID: cleanup.preparationID,
            proposedRunID: cleanup.proposedRunID,
            sessionHandle: cleanup.sessionHandle,
            hostProcessEpoch: cleanup.hostProcessEpoch,
            cleanupSequence: cleanup.cleanupSequence,
            closeDisposition: .closed,
            receiptDigest: try digestPreparedClose(cleanup, disposition: .closed)
        )
        let previous = document
        record.state = .closed
        record.cleanup = cleanup
        record.closeReceipt = receipt
        document.preparedSessions[cleanup.preparationID] = record
        do { try persist() } catch { document = previous; throw error }
        return receipt
    }

    func acknowledgePreparedSessionCleanup(
        _ cleanup: SwiftPreparedSessionCleanupEnvelope
    ) throws -> SwiftPreparedSessionCleanupAcknowledgement {
        guard var record = document.preparedSessions[cleanup.preparationID] else {
            throw cleanupMismatch()
        }
        let exact = cleanup.proposedRunID == record.session.proposedRunID
            && cleanup.sessionHandle == record.session.sessionHandle
            && cleanup.hostProcessEpoch == record.session.hostProcessEpoch
            && cleanup.registrationDigest == record.session.registrationDigest
        guard exact, record.state == .prepared else { throw cleanupMismatch() }
        let acknowledgement = SwiftPreparedSessionCleanupAcknowledgement.from(cleanup)
        if let existing = record.cleanupAcknowledgement {
            guard existing == acknowledgement, record.cleanup == cleanup else {
                throw cleanupMismatch()
            }
            return existing
        }
        let previous = document
        record.cleanup = cleanup
        record.cleanupAcknowledgement = acknowledgement
        document.preparedSessions[cleanup.preparationID] = record
        do { try persist() } catch { document = previous; throw error }
        return acknowledgement
    }

    public func preparedSessionState(preparationID: String) -> StoredPreparedSessionState? {
        document.preparedSessions[preparationID]?.state
    }

    func failNextPersistenceForTesting() {
        injectedPersistenceFailure = true
    }

    private func persist() throws {
        if injectedPersistenceFailure {
            injectedPersistenceFailure = false
            throw HostBindingSagaError(
                code: "llm_store.injected_persistence_failure",
                message: "injected LLM store persistence failure"
            )
        }
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: [.atomic])
    }
}

private func cleanupMismatch() -> RunPreparationCoordinatorError {
    RunPreparationCoordinatorError(
        code: "preparation.cleanup_mismatch",
        message: "cleanup envelope does not match the prepared session identity"
    )
}

private func cleanupNotAcknowledged() -> RunPreparationCoordinatorError {
    RunPreparationCoordinatorError(
        code: "preparation.cleanup_not_acknowledged",
        message: "cleanup must be durably acknowledged before closing the prepared session"
    )
}
