import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Security

public enum CredentialCreationPhase: String, Equatable, Sendable {
    case intent
    case stagedWritten = "staged_written"
    case slotPublished = "slot_published"
    case keyPromoted = "key_promoted"
    case complete
}

extension CredentialCreationPhase: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown credential creation phase"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CredentialCreationOperation: Codable, Equatable, Sendable {
    public let operationID: String
    public let credentialRef: String
    public let generation: UInt64
    public var phase: CredentialCreationPhase

    public init(
        operationID: String,
        credentialRef: String,
        generation: UInt64,
        phase: CredentialCreationPhase
    ) {
        self.operationID = operationID
        self.credentialRef = credentialRef
        self.generation = generation
        self.phase = phase
    }
}

public enum CredentialSlotLifecycle: Equatable, Sendable {
    case creating(operationID: String, generation: UInt64)
    case active
    case rotating(operationID: String, expectedGeneration: UInt64, nextGeneration: UInt64)
    case deleting(operationID: String, expectedGeneration: UInt64)

    package var indexValue: String {
        switch self {
        case .creating: "creating"
        case .active: "active"
        case .rotating: "rotating"
        case .deleting: "deleting"
        }
    }

    package var operationID: String? {
        switch self {
        case let .creating(operationID, _),
             let .rotating(operationID, _, _),
             let .deleting(operationID, _): operationID
        case .active: nil
        }
    }
}

extension CredentialSlotLifecycle: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case operationID = "operation_id"
        case generation
        case expectedGeneration = "expected_generation"
        case nextGeneration = "next_generation"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .tag) {
        case "creating":
            self = .creating(
                operationID: try container.decode(String.self, forKey: .operationID),
                generation: try container.decode(UInt64.self, forKey: .generation)
            )
        case "active":
            self = .active
        case "rotating":
            self = .rotating(
                operationID: try container.decode(String.self, forKey: .operationID),
                expectedGeneration: try container.decode(UInt64.self, forKey: .expectedGeneration),
                nextGeneration: try container.decode(UInt64.self, forKey: .nextGeneration)
            )
        case "deleting":
            self = .deleting(
                operationID: try container.decode(String.self, forKey: .operationID),
                expectedGeneration: try container.decode(UInt64.self, forKey: .expectedGeneration)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .tag,
                in: container,
                debugDescription: "unknown credential slot lifecycle"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .creating(operationID, generation):
            try container.encode("creating", forKey: .tag)
            try container.encode(operationID, forKey: .operationID)
            try container.encode(generation, forKey: .generation)
        case .active:
            try container.encode("active", forKey: .tag)
        case let .rotating(operationID, expectedGeneration, nextGeneration):
            try container.encode("rotating", forKey: .tag)
            try container.encode(operationID, forKey: .operationID)
            try container.encode(expectedGeneration, forKey: .expectedGeneration)
            try container.encode(nextGeneration, forKey: .nextGeneration)
        case let .deleting(operationID, expectedGeneration):
            try container.encode("deleting", forKey: .tag)
            try container.encode(operationID, forKey: .operationID)
            try container.encode(expectedGeneration, forKey: .expectedGeneration)
        }
    }
}

public struct CredentialSlotState: Codable, Equatable, Sendable {
    public let credentialRef: String
    public var currentGeneration: UInt64
    public var lifecycle: CredentialSlotLifecycle

    public init(
        credentialRef: String,
        currentGeneration: UInt64,
        lifecycle: CredentialSlotLifecycle
    ) {
        self.credentialRef = credentialRef
        self.currentGeneration = currentGeneration
        self.lifecycle = lifecycle
    }
}

public enum CredentialUsePurpose: String, Equatable, Sendable {
    case validation
    case preparation
}

extension CredentialUsePurpose: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown credential use purpose")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CredentialUseLifecycle: String, Equatable, Sendable {
    case acquired
    case sessionBound = "session_bound"
    case closing
}

extension CredentialUseLifecycle: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown credential use lifecycle")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CredentialUseLease: Codable, Equatable, Sendable {
    public let leaseID: String
    public let credentialRef: String
    public let generation: UInt64
    public let purpose: CredentialUsePurpose
    public let preparationID: String?
    public let hostProcessEpoch: HostProcessEpoch
    public var revision: UInt64
    public var lifecycle: CredentialUseLifecycle

    public init(
        leaseID: String,
        credentialRef: String,
        generation: UInt64,
        purpose: CredentialUsePurpose,
        preparationID: String?,
        hostProcessEpoch: HostProcessEpoch,
        revision: UInt64 = 1,
        lifecycle: CredentialUseLifecycle = .acquired
    ) {
        self.leaseID = leaseID
        self.credentialRef = credentialRef
        self.generation = generation
        self.purpose = purpose
        self.preparationID = preparationID
        self.hostProcessEpoch = hostProcessEpoch
        self.revision = revision
        self.lifecycle = lifecycle
    }
}

struct VersionedCredentialRecord<Value: Codable & Sendable>: Codable, Sendable {
    let recordSchemaVersion: Int
    let value: Value

    enum CodingKeys: String, CodingKey {
        case recordSchemaVersion = "record_schema_version"
        case value
    }

    init(_ value: Value) {
        recordSchemaVersion = 2
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordSchemaVersion = try container.decode(Int.self, forKey: .recordSchemaVersion)
        guard recordSchemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: container,
                debugDescription: "unsupported credential record schema"
            )
        }
        value = try container.decode(Value.self, forKey: .value)
    }
}

public actor ProviderCredentialStore {
    let database: SQLiteConnection
    let vault: any CredentialVault
    let faultInjector: (@Sendable (CredentialLifecycleCheckpoint) throws -> Void)?

    package init(
        database: SQLiteConnection,
        vault: any CredentialVault,
        faultInjector: (@Sendable (CredentialLifecycleCheckpoint) throws -> Void)? = nil
    ) throws {
        guard try LLMStoreSchema.userVersion(database) == 2 else {
            throw credentialStoreFailure(
                "credential.schema_not_ready",
                "credential store requires the pre-created LLM schema version 2"
            )
        }
        self.database = database
        self.vault = vault
        self.faultInjector = faultInjector
        try validatePersistedRecords()
        try validatePersistedLifecycleRecords()
    }

    package init(
        fileURL: URL,
        vault: any CredentialVault,
        faultInjector: (@Sendable (CredentialLifecycleCheckpoint) throws -> Void)? = nil
    ) throws {
        let database = try SQLiteConnection(path: fileURL.path)
        try self.init(database: database, vault: vault, faultInjector: faultInjector)
    }

    public func createSlot(
        credentialRef: String,
        initialSecret: SecretBytes,
        operationID: String
    ) async throws {
        defer { initialSecret.erase() }
        guard !credentialRef.isEmpty, !operationID.isEmpty else {
            throw credentialStoreFailure("credential.invalid_identity", "credential identity is empty")
        }
        var operation = try ensureCreationOperation(
            operationID: operationID,
            credentialRef: credentialRef
        )
        if operation.phase == .complete { return }
        try faultInjector?(.creationIntentPersisted)

        if operation.phase == .intent {
            try await vault.writeStaged(
                credentialRef: credentialRef,
                generation: operation.generation,
                operationID: operationID,
                secret: initialSecret
            )
            operation = try advance(operation, to: .stagedWritten)
            try faultInjector?(.creationStagedWritten)
        }
        if operation.phase == .stagedWritten {
            operation = try publishCreatingSlot(operation)
            try faultInjector?(.creationSlotPublished)
        }
        if operation.phase == .slotPublished {
            try await vault.promoteStaged(
                credentialRef: credentialRef,
                generation: operation.generation,
                operationID: operationID
            )
            operation = try advance(operation, to: .keyPromoted)
            try faultInjector?(.creationKeyPromoted)
        }
        if operation.phase == .keyPromoted {
            try activateCreatedSlot(operation)
            try faultInjector?(.creationActivated)
        }
    }

    public func operation(_ operationID: String) throws -> CredentialCreationOperation? {
        try readOperation(operationID)
    }

    public func slot(_ credentialRef: String) throws -> CredentialSlotState? {
        try readSlot(credentialRef)
    }

    public func lease(_ leaseID: String) throws -> CredentialUseLease? {
        try readLease(leaseID)
    }

    public func acquireUseLease(
        credentialRef: String,
        purpose: CredentialUsePurpose,
        preparationID: String?,
        hostProcessEpoch: HostProcessEpoch
    ) throws -> CredentialUseLease {
        switch purpose {
        case .validation:
            guard preparationID == nil else {
                throw credentialStoreFailure("credential.invalid_lease_purpose", "validation lease cannot name a preparation")
            }
        case .preparation:
            guard let preparationID, !preparationID.isEmpty else {
                throw credentialStoreFailure("credential.invalid_lease_purpose", "preparation lease requires a preparation ID")
            }
        }
        let leaseID = try randomCredentialID()
        return try database.transaction {
            guard let slot = try readSlot(credentialRef), slot.lifecycle == .active else {
                throw credentialStoreFailure("credential.slot_not_active", "credential slot is not active")
            }
            let lease = CredentialUseLease(
                leaseID: leaseID,
                credentialRef: credentialRef,
                generation: slot.currentGeneration,
                purpose: purpose,
                preparationID: preparationID,
                hostProcessEpoch: hostProcessEpoch
            )
            try database.execute(
                """
                INSERT INTO credential_use_leases(
                  lease_id, credential_ref, generation, purpose, preparation_id,
                  host_epoch, lifecycle, revision, record_schema_version, record_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 2, ?9)
                """,
                bindings: [
                    .text(lease.leaseID), .text(lease.credentialRef),
                    .text(String(lease.generation)), .text(lease.purpose.rawValue),
                    lease.preparationID.map(SQLiteValue.text) ?? .null,
                    .text(lease.hostProcessEpoch.rawValue), .text(lease.lifecycle.rawValue),
                    .text(String(lease.revision)),
                    .text(try encodeCredentialRecord(VersionedCredentialRecord(lease))),
                ]
            )
            return lease
        }
    }

    public func releaseValidationLease(_ leaseID: String) throws {
        guard let lease = try readLease(leaseID) else { return }
        guard lease.purpose == .validation, lease.lifecycle == .acquired else {
            throw credentialStoreFailure("credential.lease_transition_invalid", "lease is not a releasable validation lease")
        }
        let changed = try database.executeChanges(
            "DELETE FROM credential_use_leases WHERE lease_id = ?1 AND purpose = 'validation' AND lifecycle = 'acquired' AND revision = ?2",
            bindings: [.text(leaseID), .text(String(lease.revision))]
        )
        guard changed == 1 else { throw leaseConflict() }
    }

    package func abortPreparationLease(
        _ leaseID: String,
        expectedRevision: UInt64
    ) throws {
        guard let lease = try readLease(leaseID) else { return }
        guard lease.purpose == .preparation,
              lease.lifecycle == .acquired,
              lease.revision == expectedRevision
        else {
            throw leaseConflict()
        }
        let changed = try database.executeChanges(
            """
            DELETE FROM credential_use_leases
            WHERE lease_id = ?1 AND purpose = 'preparation'
              AND lifecycle = 'acquired' AND revision = ?2
            """,
            bindings: [.text(leaseID), .text(String(expectedRevision))]
        )
        guard changed == 1 else { throw leaseConflict() }
    }

    public func bindPreparationLease(
        _ leaseID: String,
        expectedRevision: UInt64
    ) throws -> CredentialUseLease {
        guard let lease = try readLease(leaseID), lease.purpose == .preparation else {
            throw credentialStoreFailure("credential.lease_not_found", "preparation lease does not exist")
        }
        guard lease.lifecycle == .acquired, lease.revision == expectedRevision else {
            throw leaseConflict()
        }
        return try transitionLease(lease, to: .sessionBound)
    }

    public func beginClosingLease(
        _ leaseID: String,
        expectedRevision: UInt64
    ) throws -> CredentialUseLease {
        guard let lease = try readLease(leaseID), lease.purpose == .preparation else {
            throw credentialStoreFailure("credential.lease_not_found", "preparation lease does not exist")
        }
        guard lease.lifecycle == .sessionBound, lease.revision == expectedRevision else {
            throw leaseConflict()
        }
        return try transitionLease(lease, to: .closing)
    }

    public func closeLease(_ leaseID: String, expectedRevision: UInt64) throws {
        guard let lease = try readLease(leaseID) else { return }
        guard lease.lifecycle == .closing, lease.revision == expectedRevision else {
            throw leaseConflict()
        }
        let changed = try database.executeChanges(
            "DELETE FROM credential_use_leases WHERE lease_id = ?1 AND lifecycle = 'closing' AND revision = ?2",
            bindings: [.text(leaseID), .text(String(expectedRevision))]
        )
        guard changed == 1 else { throw leaseConflict() }
    }

    public func removeLeasesFromOldEpochs(current: HostProcessEpoch) throws -> Int {
        try database.executeChanges(
            "DELETE FROM credential_use_leases WHERE host_epoch <> ?1",
            bindings: [.text(current.rawValue)]
        )
    }

    public func withCredential<Result: Sendable>(
        for leaseID: String,
        operation: @Sendable (SecretBytes) async throws -> Result
    ) async throws -> Result {
        let lease = try authorizedLease(leaseID)
        let secret = try await vault.loadFinal(
            credentialRef: lease.credentialRef,
            generation: lease.generation
        )
        defer { secret.erase() }
        let rechecked = try authorizedLease(leaseID)
        guard rechecked == lease else { throw leaseConflict() }
        return try await operation(secret)
    }

    public func revalidatePreparationLease(
        _ leaseID: String,
        credentialRef: String,
        generation: UInt64
    ) throws -> CredentialUseLease {
        try revalidateLease(
            leaseID,
            credentialRef: credentialRef,
            generation: generation,
            purpose: .preparation
        )
    }

    package func revalidateLease(
        _ leaseID: String,
        credentialRef: String,
        generation: UInt64,
        purpose: CredentialUsePurpose
    ) throws -> CredentialUseLease {
        let lease = try authorizedLease(leaseID)
        guard lease.purpose == purpose,
              lease.credentialRef == credentialRef,
              lease.generation == generation
        else {
            throw credentialStoreFailure(
                "credential.lease_identity_mismatch",
                "credential lease does not match the authorized cloud route"
            )
        }
        return lease
    }

    package func replaceSlotLifecycleForTesting(
        credentialRef: String,
        lifecycle: CredentialSlotLifecycle
    ) throws {
        guard var slot = try readSlot(credentialRef) else {
            throw credentialStoreFailure("credential.slot_missing", "credential slot does not exist")
        }
        slot.lifecycle = lifecycle
        let changed = try database.executeChanges(
            """
            UPDATE credential_slots SET lifecycle = ?1, operation_id = ?2, record_json = ?3
            WHERE credential_ref = ?4
            """,
            bindings: [
                .text(lifecycle.indexValue),
                lifecycle.operationID.map(SQLiteValue.text) ?? .null,
                .text(try encodeCredentialRecord(VersionedCredentialRecord(slot))),
                .text(credentialRef),
            ]
        )
        guard changed == 1 else { throw credentialStoreFailure("credential.slot_conflict", "credential slot changed") }
    }

    package func persistedTextValuesForTesting() -> [String] {
        let tables = [
            "credential_creation_operations",
            "credential_slots",
            "credential_use_leases",
            "credential_operation_tombstones",
            "credential_key_tombstones",
        ]
        return tables.flatMap { table in
            ((try? database.query("SELECT * FROM \(table)")) ?? []).flatMap { row in
                row.values.compactMap { $0 }
            }
        }
    }

    private func ensureCreationOperation(
        operationID: String,
        credentialRef: String
    ) throws -> CredentialCreationOperation {
        try database.transaction {
            if let existing = try readOperation(operationID) {
                guard existing.credentialRef == credentialRef, existing.generation == 1 else {
                    throw credentialStoreFailure("credential.operation_conflict", "operation ID has different creation input")
                }
                return existing
            }
            if try readSlot(credentialRef) != nil {
                throw credentialStoreFailure("credential.slot_exists", "credential slot already exists")
            }
            let competing = try database.queryRows(
                "SELECT operation_id FROM credential_creation_operations WHERE credential_ref = ?1 LIMIT 1",
                bindings: [.text(credentialRef)]
            )
            guard competing.isEmpty else {
                throw credentialStoreFailure("credential.operation_conflict", "credential already has a creation operation")
            }
            let operation = CredentialCreationOperation(
                operationID: operationID,
                credentialRef: credentialRef,
                generation: 1,
                phase: .intent
            )
            try database.execute(
                """
                INSERT INTO credential_creation_operations(
                  operation_id, credential_ref, generation, phase, record_schema_version, record_json
                ) VALUES (?1, ?2, ?3, ?4, 2, ?5)
                """,
                bindings: [
                    .text(operationID), .text(credentialRef), .text("1"),
                    .text(operation.phase.rawValue),
                    .text(try encodeCredentialRecord(VersionedCredentialRecord(operation))),
                ]
            )
            return operation
        }
    }

    func advance(
        _ operation: CredentialCreationOperation,
        to phase: CredentialCreationPhase
    ) throws -> CredentialCreationOperation {
        var updated = operation
        updated.phase = phase
        let changed = try database.executeChanges(
            """
            UPDATE credential_creation_operations SET phase = ?1, record_json = ?2
            WHERE operation_id = ?3 AND credential_ref = ?4 AND generation = ?5 AND phase = ?6
            """,
            bindings: [
                .text(phase.rawValue),
                .text(try encodeCredentialRecord(VersionedCredentialRecord(updated))),
                .text(operation.operationID), .text(operation.credentialRef),
                .text(String(operation.generation)), .text(operation.phase.rawValue),
            ]
        )
        guard changed == 1 else {
            throw credentialStoreFailure("credential.operation_conflict", "credential operation phase changed")
        }
        return updated
    }

    private func publishCreatingSlot(
        _ operation: CredentialCreationOperation
    ) throws -> CredentialCreationOperation {
        try database.transaction {
            let slot = CredentialSlotState(
                credentialRef: operation.credentialRef,
                currentGeneration: operation.generation,
                lifecycle: .creating(
                    operationID: operation.operationID,
                    generation: operation.generation
                )
            )
            try database.execute(
                """
                INSERT INTO credential_slots(
                  credential_ref, current_generation, lifecycle, operation_id,
                  record_schema_version, record_json
                ) VALUES (?1, ?2, 'creating', ?3, 2, ?4)
                """,
                bindings: [
                    .text(slot.credentialRef), .text(String(slot.currentGeneration)),
                    .text(operation.operationID),
                    .text(try encodeCredentialRecord(VersionedCredentialRecord(slot))),
                ]
            )
            return try advance(operation, to: .slotPublished)
        }
    }

    func activateCreatedSlot(_ operation: CredentialCreationOperation) throws {
        try database.transaction {
            guard var slot = try readSlot(operation.credentialRef) else {
                throw credentialStoreFailure("credential.slot_missing", "creating credential slot is missing")
            }
            guard slot.lifecycle == .creating(
                operationID: operation.operationID,
                generation: operation.generation
            ) else {
                throw credentialStoreFailure("credential.slot_conflict", "creating credential slot changed")
            }
            slot.lifecycle = .active
            let slotChanged = try database.executeChanges(
                """
                UPDATE credential_slots SET lifecycle = 'active', operation_id = NULL, record_json = ?1
                WHERE credential_ref = ?2 AND current_generation = ?3
                  AND lifecycle = 'creating' AND operation_id = ?4
                """,
                bindings: [
                    .text(try encodeCredentialRecord(VersionedCredentialRecord(slot))),
                    .text(operation.credentialRef), .text(String(operation.generation)),
                    .text(operation.operationID),
                ]
            )
            guard slotChanged == 1 else {
                throw credentialStoreFailure("credential.slot_conflict", "creating credential slot changed")
            }
            _ = try advance(operation, to: .complete)
        }
    }

    private func transitionLease(
        _ lease: CredentialUseLease,
        to lifecycle: CredentialUseLifecycle
    ) throws -> CredentialUseLease {
        guard lease.revision < UInt64.max else {
            throw credentialStoreFailure("credential.lease_revision_overflow", "credential lease revision overflow")
        }
        var updated = lease
        updated.lifecycle = lifecycle
        updated.revision += 1
        let changed = try database.executeChanges(
            """
            UPDATE credential_use_leases SET lifecycle = ?1, revision = ?2, record_json = ?3
            WHERE lease_id = ?4 AND lifecycle = ?5 AND revision = ?6
            """,
            bindings: [
                .text(lifecycle.rawValue), .text(String(updated.revision)),
                .text(try encodeCredentialRecord(VersionedCredentialRecord(updated))),
                .text(lease.leaseID), .text(lease.lifecycle.rawValue),
                .text(String(lease.revision)),
            ]
        )
        guard changed == 1 else { throw leaseConflict() }
        return updated
    }

    private func authorizedLease(_ leaseID: String) throws -> CredentialUseLease {
        guard let lease = try readLease(leaseID) else {
            throw credentialStoreFailure("credential.lease_not_found", "credential lease does not exist")
        }
        guard lease.lifecycle == .acquired || lease.lifecycle == .sessionBound else {
            throw credentialStoreFailure("credential.lease_not_usable", "credential lease is closing")
        }
        guard let slot = try readSlot(lease.credentialRef),
              slot.lifecycle == .active,
              slot.currentGeneration == lease.generation
        else {
            throw credentialStoreFailure("credential.generation_changed", "credential generation is no longer authoritative")
        }
        return lease
    }

    nonisolated func readOperation(_ operationID: String) throws -> CredentialCreationOperation? {
        let rows = try database.queryRows(
            "SELECT operation_id, credential_ref, generation, phase, record_schema_version, record_json FROM credential_creation_operations WHERE operation_id = ?1",
            bindings: [.text(operationID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptCredentialRecord("creation operation") }
        let value = try decodeCredentialRecord(
            VersionedCredentialRecord<CredentialCreationOperation>.self,
            json: json
        ).value
        guard row.text("operation_id") == value.operationID,
              row.text("credential_ref") == value.credentialRef,
              row.text("generation") == String(value.generation),
              row.text("phase") == value.phase.rawValue
        else { throw corruptCredentialRecord("creation operation index") }
        return value
    }

    nonisolated func readSlot(_ credentialRef: String) throws -> CredentialSlotState? {
        let rows = try database.queryRows(
            "SELECT credential_ref, current_generation, lifecycle, operation_id, record_schema_version, record_json FROM credential_slots WHERE credential_ref = ?1",
            bindings: [.text(credentialRef)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptCredentialRecord("credential slot") }
        let value = try decodeCredentialRecord(
            VersionedCredentialRecord<CredentialSlotState>.self,
            json: json
        ).value
        guard row.text("credential_ref") == value.credentialRef,
              row.text("current_generation") == String(value.currentGeneration),
              row.text("lifecycle") == value.lifecycle.indexValue,
              row.text("operation_id") == value.lifecycle.operationID
        else { throw corruptCredentialRecord("credential slot index") }
        return value
    }

    nonisolated func readLease(_ leaseID: String) throws -> CredentialUseLease? {
        let rows = try database.queryRows(
            "SELECT lease_id, credential_ref, generation, purpose, preparation_id, host_epoch, lifecycle, revision, record_schema_version, record_json FROM credential_use_leases WHERE lease_id = ?1",
            bindings: [.text(leaseID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptCredentialRecord("credential lease") }
        let value = try decodeCredentialRecord(
            VersionedCredentialRecord<CredentialUseLease>.self,
            json: json
        ).value
        guard row.text("lease_id") == value.leaseID,
              row.text("credential_ref") == value.credentialRef,
              row.text("generation") == String(value.generation),
              row.text("purpose") == value.purpose.rawValue,
              row.text("preparation_id") == value.preparationID,
              row.text("host_epoch") == value.hostProcessEpoch.rawValue,
              row.text("lifecycle") == value.lifecycle.rawValue,
              row.text("revision") == String(value.revision)
        else { throw corruptCredentialRecord("credential lease index") }
        return value
    }

    nonisolated private func validatePersistedRecords() throws {
        for row in try database.queryRows("SELECT operation_id FROM credential_creation_operations") {
            guard let id = row.text("operation_id") else { throw corruptCredentialRecord("creation operation") }
            _ = try readOperation(id)
        }
        for row in try database.queryRows("SELECT credential_ref FROM credential_slots") {
            guard let id = row.text("credential_ref") else { throw corruptCredentialRecord("credential slot") }
            _ = try readSlot(id)
        }
        for row in try database.queryRows("SELECT lease_id FROM credential_use_leases") {
            guard let id = row.text("lease_id") else { throw corruptCredentialRecord("credential lease") }
            _ = try readLease(id)
        }
    }
}

func encodeCredentialRecord<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func decodeCredentialRecord<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
        throw corruptCredentialRecord("versioned JSON")
    }
}

private func randomCredentialID() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw credentialStoreFailure("credential.random_failed", "secure random generation failed")
    }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func credentialStoreFailure(_ code: String, _ message: String) -> CredentialFailure {
    CredentialFailure(code: code, message: message)
}

func corruptCredentialRecord(_ subject: String) -> CredentialFailure {
    credentialStoreFailure("credential.corrupt_record", "invalid persisted \(subject)")
}

private func leaseConflict() -> CredentialFailure {
    credentialStoreFailure("credential.lease_revision_conflict", "credential lease changed")
}
