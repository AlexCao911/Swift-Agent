import Foundation

public struct LLMStoreError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ActiveAgentHostBinding: Equatable, Sendable {
    public let configuration: AgentHostConfiguration
    public let binding: HostBindingTuple

    public init(
        configuration: AgentHostConfiguration,
        binding: HostBindingTuple
    ) {
        self.configuration = configuration
        self.binding = binding
    }

    public var targetReference: LLMTargetReference {
        configuration.selectedTarget
    }
}

private struct TargetKey: Hashable, Sendable {
    let id: String
    let revision: UInt64
}

package struct PersistedTargetRevision: Codable, Sendable {
    package let recordSchemaVersion: Int
    package let target: LLMTargetRevision

    enum CodingKeys: String, CodingKey {
        case recordSchemaVersion = "record_schema_version"
        case target
    }

    package init(target: LLMTargetRevision) {
        recordSchemaVersion = 2
        self.target = target
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordSchemaVersion = try container.decode(Int.self, forKey: .recordSchemaVersion)
        guard recordSchemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: container,
                debugDescription: "unsupported LLM-target record schema"
            )
        }
        target = try container.decode(LLMTargetRevision.self, forKey: .target)
    }
}

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
    private let database: SQLiteConnection
    private var document: LLMStoreDocument
    private var targetRevisions: [TargetKey: LLMTargetRevision]
    private var injectedPersistenceFailure = false

    public static func inMemory() -> LLMStore {
        try! LLMStore(fileURL: nil)
    }

    public init(fileURL: URL) throws {
        try self.init(fileURL: Optional(fileURL))
    }

    private init(fileURL: URL?) throws {
        let legacyDocument: LLMStoreDocument?
        if let fileURL, Self.isLegacyJSONFile(fileURL) {
            legacyDocument = try JSONDecoder().decode(
                LLMStoreDocument.self,
                from: Data(contentsOf: fileURL)
            )
        } else {
            legacyDocument = nil
        }
        if let fileURL {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        if let fileURL, let legacyDocument {
            database = try Self.migrateLegacy(
                legacyDocument,
                at: fileURL
            )
        } else {
            database = try SQLiteConnection(path: fileURL?.path ?? ":memory:")
            try LLMStoreSchema.migrateToCurrent(database)
        }
        document = try Self.loadDocument(from: database)
        targetRevisions = try Self.loadTargets(from: database)
    }

    public func publishTarget(_ target: LLMTargetRevision) throws {
        let key = TargetKey(id: target.targetID.rawValue, revision: target.revision)
        if let existing = targetRevisions[key] {
            guard existing == target else {
                throw targetFailure(
                    "llm_target.revision_conflict",
                    "LLM target revision is immutable"
                )
            }
            return
        }
        guard !target.targetID.rawValue.isEmpty,
              target.revision > 0,
              !target.modelID.isEmpty
        else {
            throw targetFailure(
                "llm_target.invalid_revision",
                "LLM target identity is invalid"
            )
        }
        let latest = targetRevisions.values
            .filter { $0.targetID == target.targetID }
            .map(\.revision)
            .max() ?? 0
        guard target.revision > latest else {
            throw targetFailure(
                "llm_target.revision_not_monotonic",
                "LLM target revision must increase"
            )
        }
        do {
            try database.transaction {
                try consumeInjectedFailure()
                let (kind, profileID, profileRevision): (
                    String,
                    SQLiteValue,
                    SQLiteValue
                ) = switch target.kind {
                case .local:
                    ("local", .null, .null)
                case let .cloud(id, revision):
                    ("cloud", .text(id), .text(String(revision)))
                }
                try database.execute(
                    """
                    INSERT INTO llm_target_revisions(
                      target_id, revision, kind, model_id, profile_id, profile_revision,
                      record_schema_version, record_json
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 2, ?7)
                    """,
                    bindings: [
                        .text(target.targetID.rawValue),
                        .text(String(target.revision)),
                        .text(kind),
                        .text(target.modelID),
                        profileID,
                        profileRevision,
                        .text(try Self.encode(PersistedTargetRevision(target: target))),
                    ]
                )
            }
        } catch let failure as LLMStoreError {
            throw failure
        } catch {
            throw targetFailure(
                "llm_target.persistence_failed",
                "could not persist LLM target revision"
            )
        }
        targetRevisions[key] = target
    }

    public func target(reference: LLMTargetReference) -> LLMTargetRevision? {
        targetRevisions[
            TargetKey(id: reference.targetID.rawValue, revision: reference.revision)
        ]
    }

    public func targets() -> [LLMTargetRevision] {
        targetRevisions.values.sorted {
            ($0.targetID.rawValue, $0.revision) < ($1.targetID.rawValue, $1.revision)
        }
    }

    public func activeHostBindings() throws -> [ActiveAgentHostBinding] {
        try document.hostBindings.values
            .filter { $0.state == .active }
            .map { record in
                let configuration = record.request.configuration
                let binding = record.receipt.binding
                guard record.request.llmSlotID == configuration.llmSlotID,
                      record.request.requirementsHash == configuration.requirementsHash,
                      binding.bindingID == configuration.bindingID,
                      binding.bindingRevision == configuration.revision,
                      binding.bindingHash == (try agentHostConfigurationDigest(configuration)),
                      target(reference: configuration.selectedTarget) != nil
                else {
                    throw targetFailure(
                        "host_binding.persisted_record_invalid",
                        "active host binding does not match its exact target and digest"
                    )
                }
                return ActiveAgentHostBinding(
                    configuration: configuration,
                    binding: binding
                )
            }
            .sorted {
                let lhs = $0.configuration
                let rhs = $1.configuration
                return (
                    lhs.agentProfileID,
                    lhs.agentProfileRevision,
                    lhs.llmSlotID,
                    lhs.bindingID,
                    lhs.revision
                ) < (
                    rhs.agentProfileID,
                    rhs.agentProfileRevision,
                    rhs.llmSlotID,
                    rhs.bindingID,
                    rhs.revision
                )
            }
    }

    func stage(_ record: StoredHostBindingRecord) throws -> HostBindingStagingReceipt {
        let key = record.request.tokenDigest
        if let existing = document.hostBindings[key] {
            guard sameHostBindingIdentity(existing, record) else {
                throw HostBindingSagaError(
                    code: "host_binding.idempotency_conflict",
                    message: "operation token was replayed with different staging input"
                )
            }
            return existing.receipt
        }
        let previous = document
        document.hostBindings[key] = record
        do {
            try insertHostBinding(record)
        } catch {
            document = previous
            throw error
        }
        return record.receipt
    }

    func activate(token: String, binding: HostBindingTuple) throws {
        guard let key = hostBindingKey(token), var record = document.hostBindings[key] else {
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
        document.hostBindings[key] = record
        do {
            try updateHostBinding(record, expectedState: .staged)
        } catch {
            document = previous
            throw error
        }
    }

    func record(token: String) -> StoredHostBindingRecord? {
        hostBindingKey(token).flatMap { document.hostBindings[$0] }
    }

    public func bindingState(token: String) -> StoredHostBindingState? {
        hostBindingKey(token).flatMap { document.hostBindings[$0]?.state }
    }

    func activeBinding(
        configuration: AgentHostConfiguration,
        bindingHash: String
    ) -> HostBindingTuple? {
        document.hostBindings.values.first { record in
            record.state == .active
                && record.request.configuration == configuration
                && record.receipt.binding.bindingID == configuration.bindingID
                && record.receipt.binding.bindingRevision == configuration.revision
                && record.receipt.binding.bindingHash == bindingHash
        }?.receipt.binding
    }

    func prepareSession(_ record: StoredPreparedSessionRecord) throws -> SwiftPreparedSession {
        let id = record.session.preparationID
        if let existing = document.preparedSessions[id] {
            guard samePreparedIdentity(existing, record) else {
                throw RunPreparationCoordinatorError(
                    code: "preparation.idempotency_conflict",
                    message: "preparation was replayed with a different Swift snapshot"
                )
            }
            return existing.session
        }
        let previous = document
        document.preparedSessions[id] = record
        do { try insertPreparedSession(record) } catch { document = previous; throw error }
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
        do { try updatePreparedSession(record, expectedState: .prepared) } catch { document = previous; throw error }
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
        do { try updatePreparedSession(record, expectedState: .prepared) } catch { document = previous; throw error }
        return acknowledgement
    }

    public func preparedSessionState(preparationID: String) -> StoredPreparedSessionState? {
        document.preparedSessions[preparationID]?.state
    }

    func failNextPersistenceForTesting() {
        injectedPersistenceFailure = true
    }

    package func schemaVersionForTesting() -> UInt64 {
        guard let rows = try? database.query("PRAGMA user_version"),
              let first = rows.first,
              let wrapped = first["user_version"],
              let value = wrapped
        else { return 0 }
        return UInt64(value) ?? 0
    }

    func tableNamesForTesting() -> [String] {
        (try? database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).compactMap { $0["name"] ?? nil }) ?? []
    }

    func allTextValuesForTesting() -> [String] {
        let hostRows = (try? database.query(
            "SELECT operation_token, state, binding_id, binding_revision, binding_hash, record_json FROM host_bindings"
        )) ?? []
        let sessionRows = (try? database.query(
            "SELECT preparation_id, state, registration_digest, cleanup_command_id, record_json FROM prepared_sessions"
        )) ?? []
        return (hostRows + sessionRows).flatMap { row in
            row.values.compactMap { $0 }
        }
    }

    private func insertHostBinding(_ record: StoredHostBindingRecord) throws {
        try database.transaction {
            try consumeInjectedFailure()
            let persisted = Self.persistedHostBinding(record)
            let json = try Self.encode(persisted)
            try database.execute(
                """
                INSERT INTO host_bindings(
                  operation_token, state, binding_id, binding_revision, binding_hash, record_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """,
                bindings: [
                    .text(record.request.tokenDigest),
                    .text(record.state.rawValue),
                    .text(record.receipt.binding.bindingID),
                    .text(String(record.receipt.binding.bindingRevision)),
                    .text(record.receipt.binding.bindingHash),
                    .text(json),
                ]
            )
        }
    }

    private func updateHostBinding(
        _ record: StoredHostBindingRecord,
        expectedState: StoredHostBindingState
    ) throws {
        try database.transaction {
            try consumeInjectedFailure()
            let persisted = Self.persistedHostBinding(record)
            let changed = try database.executeChanges(
                """
                UPDATE host_bindings SET state = ?1, record_json = ?2
                WHERE operation_token = ?3 AND state = ?4
                  AND binding_id = ?5 AND binding_revision = ?6 AND binding_hash = ?7
                """,
                bindings: [
                    .text(record.state.rawValue), .text(try Self.encode(persisted)),
                    .text(record.request.tokenDigest), .text(expectedState.rawValue),
                    .text(record.receipt.binding.bindingID),
                    .text(String(record.receipt.binding.bindingRevision)),
                    .text(record.receipt.binding.bindingHash),
                ]
            )
            guard changed == 1 else { throw staleCAS() }
        }
    }

    private func insertPreparedSession(_ record: StoredPreparedSessionRecord) throws {
        try database.transaction {
            try consumeInjectedFailure()
            let persisted = Self.persistedPreparedSession(record)
            let json = try Self.encode(persisted)
            try database.execute(
                """
                INSERT INTO prepared_sessions(
                  preparation_id, state, registration_digest, cleanup_command_id, record_json
                ) VALUES (?1, ?2, ?3, ?4, ?5)
                """,
                bindings: [
                    .text(record.session.preparationID),
                    .text(record.state.rawValue),
                    .text(record.session.registrationDigest),
                    record.cleanup.map { .text($0.cleanupCommandID) } ?? .null,
                    .text(json),
                ]
            )
        }
    }

    private func updatePreparedSession(
        _ record: StoredPreparedSessionRecord,
        expectedState: StoredPreparedSessionState
    ) throws {
        try database.transaction {
            try consumeInjectedFailure()
            let persisted = Self.persistedPreparedSession(record)
            let changed = try database.executeChanges(
                """
                UPDATE prepared_sessions SET state = ?1, cleanup_command_id = ?2, record_json = ?3
                WHERE preparation_id = ?4 AND state = ?5 AND registration_digest = ?6
                """,
                bindings: [
                    .text(record.state.rawValue),
                    record.cleanup.map { .text($0.cleanupCommandID) } ?? .null,
                    .text(try Self.encode(persisted)),
                    .text(record.session.preparationID), .text(expectedState.rawValue),
                    .text(record.session.registrationDigest),
                ]
            )
            guard changed == 1 else { throw staleCAS() }
        }
    }

    private func consumeInjectedFailure() throws {
        if injectedPersistenceFailure {
            injectedPersistenceFailure = false
            throw HostBindingSagaError(
                code: "llm_store.injected_persistence_failure",
                message: "injected LLM store persistence failure"
            )
        }
    }

    private static func loadDocument(from database: SQLiteConnection) throws -> LLMStoreDocument {
        var document = LLMStoreDocument()
        for row in try database.query("SELECT operation_token, record_json FROM host_bindings") {
            guard let token = row["operation_token"] ?? nil,
                  let json = row["record_json"] ?? nil
            else { continue }
            document.hostBindings[token] = try JSONDecoder().decode(
                StoredHostBindingRecord.self,
                from: Data(json.utf8)
            )
        }
        for row in try database.query("SELECT preparation_id, record_json FROM prepared_sessions") {
            guard let id = row["preparation_id"] ?? nil,
                  let json = row["record_json"] ?? nil
            else { continue }
            document.preparedSessions[id] = try JSONDecoder().decode(
                StoredPreparedSessionRecord.self,
                from: Data(json.utf8)
            )
        }
        return document
    }

    private static func loadTargets(
        from database: SQLiteConnection
    ) throws -> [TargetKey: LLMTargetRevision] {
        var targets: [TargetKey: LLMTargetRevision] = [:]
        for row in try database.query(
            """
            SELECT target_id, revision, kind, model_id, profile_id, profile_revision,
                   record_schema_version, record_json
            FROM llm_target_revisions
            """
        ) {
            guard row["record_schema_version"] == "2",
                  let id = row["target_id"] ?? nil,
                  let revisionText = row["revision"] ?? nil,
                  let revision = UInt64(revisionText),
                  String(revision) == revisionText,
                  let kind = row["kind"] ?? nil,
                  let modelID = row["model_id"] ?? nil,
                  let json = row["record_json"] ?? nil
            else {
                throw targetFailure(
                    "llm_target.persisted_record_invalid",
                    "LLM target record identity is invalid"
                )
            }
            let value: LLMTargetRevision
            do {
                value = try JSONDecoder().decode(
                    PersistedTargetRevision.self,
                    from: Data(json.utf8)
                ).target
            } catch {
                throw targetFailure(
                    "llm_target.persisted_record_invalid",
                    "LLM target record schema is unsupported"
                )
            }
            let kindMatches = switch value.kind {
            case .local:
                kind == "local"
                    && (row["profile_id"] ?? nil) == nil
                    && (row["profile_revision"] ?? nil) == nil
            case let .cloud(profileID, profileRevision):
                kind == "cloud"
                    && (row["profile_id"] ?? nil) == profileID
                    && (row["profile_revision"] ?? nil) == String(profileRevision)
            }
            guard kindMatches,
                  value.targetID.rawValue == id,
                  value.revision == revision,
                  value.modelID == modelID
            else {
                throw targetFailure(
                    "llm_target.persisted_record_invalid",
                    "LLM target record payload differs from its indexed identity"
                )
            }
            targets[TargetKey(id: id, revision: revision)] = value
        }
        return targets
    }

    private static func importLegacy(
        _ document: LLMStoreDocument,
        into database: SQLiteConnection
    ) throws {
        try database.transaction {
            for record in document.hostBindings.values {
                try database.execute(
                    "INSERT INTO host_bindings(operation_token, state, binding_id, binding_revision, binding_hash, record_json) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    bindings: [
                        .text(record.request.tokenDigest), .text(record.state.rawValue),
                        .text(record.receipt.binding.bindingID),
                        .text(String(record.receipt.binding.bindingRevision)),
                        .text(record.receipt.binding.bindingHash),
                        .text(try encode(persistedHostBinding(record))),
                    ]
                )
            }
            for record in document.preparedSessions.values {
                try database.execute(
                    "INSERT INTO prepared_sessions(preparation_id, state, registration_digest, cleanup_command_id, record_json) VALUES (?1, ?2, ?3, ?4, ?5)",
                    bindings: [
                        .text(record.session.preparationID), .text(record.state.rawValue),
                        .text(record.session.registrationDigest),
                        record.cleanup.map { .text($0.cleanupCommandID) } ?? .null,
                        .text(try encode(persistedPreparedSession(record))),
                    ]
                )
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func hostBindingKey(_ tokenOrDigest: String) -> String? {
        if document.hostBindings[tokenOrDigest] != nil { return tokenOrDigest }
        return document.hostBindings.first(where: {
            $0.value.request.operationToken == tokenOrDigest
                || $0.value.request.tokenDigest == tokenOrDigest
        })?.key
    }

    private func sameHostBindingIdentity(
        _ left: StoredHostBindingRecord,
        _ right: StoredHostBindingRecord
    ) -> Bool {
        left.request.tokenDigest == right.request.tokenDigest
            && left.request.llmSlotID == right.request.llmSlotID
            && left.request.requirementsHash == right.request.requirementsHash
            && left.request.configuration == right.request.configuration
            && left.receipt == right.receipt
    }

    private func samePreparedIdentity(
        _ left: StoredPreparedSessionRecord,
        _ right: StoredPreparedSessionRecord
    ) -> Bool {
        let lhs = left.request.preview
        let rhs = right.request.preview
        return left.session == right.session
            && left.request.configuration == right.request.configuration
            && lhs.preparationID == rhs.preparationID
            && lhs.proposedRunID == rhs.proposedRunID
            && lhs.bindingDigest == rhs.bindingDigest
            && lhs.hostProcessEpoch == rhs.hostProcessEpoch
            && lhs.expirationMillis == rhs.expirationMillis
    }

    private static func persistedHostBinding(
        _ record: StoredHostBindingRecord
    ) -> StoredHostBindingRecord {
        StoredHostBindingRecord(
            request: HostBindingStageRequest(
                operationToken: "",
                tokenDigest: record.request.tokenDigest,
                llmSlotID: record.request.llmSlotID,
                requirementsHash: record.request.requirementsHash,
                configuration: record.request.configuration
            ),
            receipt: record.receipt,
            state: record.state
        )
    }

    private static func persistedPreparedSession(
        _ record: StoredPreparedSessionRecord
    ) -> StoredPreparedSessionRecord {
        let preview = record.request.preview
        return StoredPreparedSessionRecord(
            request: SwiftRunPreparationRequest(
                preview: SwiftRunPreparationPreview(
                    preparationID: preview.preparationID,
                    proposedRunID: preview.proposedRunID,
                    token: "",
                    bindingDigest: preview.bindingDigest,
                    hostProcessEpoch: preview.hostProcessEpoch,
                    expirationMillis: preview.expirationMillis
                ),
                configuration: record.request.configuration
            ),
            session: record.session,
            state: record.state,
            cleanup: record.cleanup,
            cleanupAcknowledgement: record.cleanupAcknowledgement,
            closeReceipt: record.closeReceipt
        )
    }

    private static func isLegacyJSONFile(_ fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              !data.isEmpty
        else { return false }
        return !data.starts(with: Data("SQLite format 3\0".utf8))
    }

    private static func migrateLegacy(
        _ document: LLMStoreDocument,
        at fileURL: URL
    ) throws -> SQLiteConnection {
        let importing = fileURL.appendingPathExtension("importing")
        let backup = fileURL.appendingPathExtension("migrated")
        guard !FileManager.default.fileExists(atPath: backup.path) else {
            throw SQLiteStoreError(
                code: "llm_store.legacy_backup_exists",
                message: "legacy migration backup already exists"
            )
        }
        try? FileManager.default.removeItem(at: importing)
        let database = try SQLiteConnection(path: importing.path)
        do {
            try LLMStoreSchema.migrateToCurrent(database)
            try importLegacy(document, into: database)
        } catch {
            try? FileManager.default.removeItem(at: importing)
            throw error
        }
        try FileManager.default.moveItem(at: fileURL, to: backup)
        do {
            try FileManager.default.moveItem(at: importing, to: fileURL)
            return database
        } catch {
            try? FileManager.default.moveItem(at: backup, to: fileURL)
            try? FileManager.default.removeItem(at: importing)
            throw error
        }
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

private func staleCAS() -> HostBindingSagaError {
    HostBindingSagaError(
        code: "llm_store.cas_conflict",
        message: "LLM store record changed before the transactional update"
    )
}

private func targetFailure(_ code: String, _ message: String) -> LLMStoreError {
    LLMStoreError(code: code, message: message)
}
