import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore

public enum CredentialLifecycleCheckpoint: String, Equatable, Sendable {
    case creationIntentPersisted = "creation.intent_persisted"
    case creationStagedWritten = "creation.staged_written"
    case creationSlotPublished = "creation.slot_published"
    case creationKeyPromoted = "creation.key_promoted"
    case creationActivated = "creation.activated"
    case rotationSlotLocked = "rotation.slot_locked"
    case rotationStagedWritten = "rotation.staged_written"
    case rotationPromotionStarted = "rotation.promotion_started"
    case rotationKeyPromoted = "rotation.key_promoted"
    case rotationPublished = "rotation.published"
    case rotationOldKeyTombstoned = "rotation.old_key_tombstoned"
    case rotationOldKeyDeleted = "rotation.old_key_deleted"
    case deletionSlotLocked = "deletion.slot_locked"
    case deletionKeyTombstoned = "deletion.key_tombstoned"
    case deletionKeyDeleted = "deletion.key_deleted"
}

public enum CredentialLifecycleOperationKind: String, Equatable, Sendable {
    case rotation
    case deletion
}

extension CredentialLifecycleOperationKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown credential operation kind"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CredentialLifecycleOperationPhase: String, Equatable, Sendable {
    case rotationSlotLocked = "rotation_slot_locked"
    case rotationStagedWritten = "rotation_staged_written"
    case rotationPromotionStarted = "rotation_promotion_started"
    case rotationKeyPromoted = "rotation_key_promoted"
    case rotationPublished = "rotation_published"
    case rotationOldKeyTombstoned = "rotation_old_key_tombstoned"
    case rotationOldKeyDeleted = "rotation_old_key_deleted"
    case deletionSlotLocked = "deletion_slot_locked"
    case deletionKeyTombstoned = "deletion_key_tombstoned"
    case deletionKeyDeleted = "deletion_key_deleted"
    case complete
    case rolledBack = "rolled_back"
}

extension CredentialLifecycleOperationPhase: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown credential operation phase"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CredentialLifecycleOperation: Codable, Equatable, Sendable {
    public let operationID: String
    public let credentialRef: String
    public let kind: CredentialLifecycleOperationKind
    public let expectedGeneration: UInt64
    public let nextGeneration: UInt64?
    public var phase: CredentialLifecycleOperationPhase

    public init(
        operationID: String,
        credentialRef: String,
        kind: CredentialLifecycleOperationKind,
        expectedGeneration: UInt64,
        nextGeneration: UInt64?,
        phase: CredentialLifecycleOperationPhase
    ) {
        self.operationID = operationID
        self.credentialRef = credentialRef
        self.kind = kind
        self.expectedGeneration = expectedGeneration
        self.nextGeneration = nextGeneration
        self.phase = phase
    }
}

public enum CredentialKeyTombstoneReason: String, Equatable, Sendable {
    case rotatedGeneration = "rotated_generation"
    case deletedSlot = "deleted_slot"
}

extension CredentialKeyTombstoneReason: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown credential key tombstone reason"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum CredentialKeyTombstonePhase: String, Equatable, Sendable {
    case deletionStarted = "deletion_started"
    case keyDeleted = "key_deleted"
    case complete
}

extension CredentialKeyTombstonePhase: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unknown credential key tombstone phase"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CredentialKeyTombstone: Codable, Equatable, Sendable {
    public let tombstoneID: String
    public let operationID: String
    public let credentialRef: String
    public let generation: UInt64
    public let reason: CredentialKeyTombstoneReason
    public var phase: CredentialKeyTombstonePhase
}

public struct CredentialReconciliationReport: Equatable, Sendable {
    public let abortedCreationOperationIDs: [String]
    public let completedCreationOperationIDs: [String]
    public let rolledBackOperationIDs: [String]
    public let completedLifecycleOperationIDs: [String]
    public let removedOldEpochLeaseCount: Int
}

public struct CredentialOperationReconciler: Sendable {
    private let credentialStore: ProviderCredentialStore
    private let currentHostProcessEpoch: HostProcessEpoch?

    public init(
        credentialStore: ProviderCredentialStore,
        currentHostProcessEpoch: HostProcessEpoch? = nil
    ) {
        self.credentialStore = credentialStore
        self.currentHostProcessEpoch = currentHostProcessEpoch
    }

    public func reconcileStartup() async throws -> CredentialReconciliationReport {
        try await credentialStore.reconcilePendingCredentialOperations(
            currentHostProcessEpoch: currentHostProcessEpoch
        )
    }
}

extension ProviderCredentialStore {
    public func lifecycleOperation(
        _ operationID: String
    ) throws -> CredentialLifecycleOperation? {
        try readLifecycleOperation(operationID)
    }

    public func rotateCredential(
        credentialRef: String,
        expectedGeneration: UInt64,
        replacement: SecretBytes,
        operationID: String
    ) async throws {
        defer { replacement.erase() }
        guard !credentialRef.isEmpty, !operationID.isEmpty else {
            throw credentialStoreFailure("credential.invalid_identity", "credential identity is empty")
        }
        var operation = try beginRotation(
            credentialRef: credentialRef,
            expectedGeneration: expectedGeneration,
            operationID: operationID
        )
        if operation.phase == .complete { return }
        if operation.phase == .rolledBack {
            throw credentialStoreFailure("credential.operation_rolled_back", "credential rotation was rolled back")
        }

        if operation.phase == .rotationSlotLocked {
            try faultInjector?(.rotationSlotLocked)
            guard let nextGeneration = operation.nextGeneration else {
                throw corruptCredentialRecord("rotation next generation")
            }
            try await vault.writeStaged(
                credentialRef: credentialRef,
                generation: nextGeneration,
                operationID: operationID,
                secret: replacement
            )
            operation = try advanceLifecycleOperation(operation, to: .rotationStagedWritten)
            try faultInjector?(.rotationStagedWritten)
        }
        if operation.phase == .rotationStagedWritten {
            guard let nextGeneration = operation.nextGeneration else {
                throw corruptCredentialRecord("rotation next generation")
            }
            guard try await !vault.finalExists(
                credentialRef: operation.credentialRef,
                generation: nextGeneration
            ) else {
                throw credentialStoreFailure(
                    "credential.untracked_keychain_item",
                    "the next generation final Keychain account already exists"
                )
            }
            operation = try advanceLifecycleOperation(
                operation,
                to: .rotationPromotionStarted
            )
            try faultInjector?(.rotationPromotionStarted)
        }
        if operation.phase == .rotationPromotionStarted {
            guard let nextGeneration = operation.nextGeneration else {
                throw corruptCredentialRecord("rotation next generation")
            }
            try await vault.promoteStaged(
                credentialRef: operation.credentialRef,
                generation: nextGeneration,
                operationID: operation.operationID
            )
            operation = try advanceLifecycleOperation(operation, to: .rotationKeyPromoted)
            try faultInjector?(.rotationKeyPromoted)
        }
        if operation.phase == .rotationKeyPromoted {
            operation = try publishRotation(operation)
            try faultInjector?(.rotationPublished)
        }
        try await finishPublishedRotation(operation)
    }

    public func beginCredentialDeletion(
        credentialRef: String,
        expectedGeneration: UInt64,
        operationID: String
    ) async throws {
        guard !credentialRef.isEmpty, !operationID.isEmpty else {
            throw credentialStoreFailure("credential.invalid_identity", "credential identity is empty")
        }
        let operation = try beginDeletion(
            credentialRef: credentialRef,
            expectedGeneration: expectedGeneration,
            operationID: operationID
        )
        if operation.phase == .complete { return }
        if operation.phase == .rolledBack {
            throw credentialStoreFailure("credential.operation_rolled_back", "credential deletion was rolled back")
        }
        if operation.phase == .deletionSlotLocked {
            try faultInjector?(.deletionSlotLocked)
        }
        try await finishDeletion(operation)
    }

    func reconcilePendingCredentialOperations(
        currentHostProcessEpoch: HostProcessEpoch?
    ) async throws -> CredentialReconciliationReport {
        var abortedCreations: [String] = []
        var completedCreations: [String] = []
        var rolledBack: [String] = []
        var completed: [String] = []

        for operation in try allCreationOperations() where operation.phase != .complete {
            switch operation.phase {
            case .intent, .stagedWritten:
                try await vault.deleteStaged(
                    credentialRef: operation.credentialRef,
                    generation: operation.generation,
                    operationID: operation.operationID
                )
                try abortUnpublishedCreation(operation)
                abortedCreations.append(operation.operationID)
            case .slotPublished:
                try await vault.promoteStaged(
                    credentialRef: operation.credentialRef,
                    generation: operation.generation,
                    operationID: operation.operationID
                )
                let promoted = try advance(operation, to: .keyPromoted)
                try activateCreatedSlot(promoted)
                completedCreations.append(operation.operationID)
            case .keyPromoted:
                try activateCreatedSlot(operation)
                completedCreations.append(operation.operationID)
            case .complete:
                break
            }
        }

        for operation in try allLifecycleOperations() {
            switch operation.kind {
            case .rotation:
                switch operation.phase {
                case .rotationSlotLocked, .rotationStagedWritten,
                     .rotationPromotionStarted, .rotationKeyPromoted:
                    try await rollbackUnpublishedRotation(operation)
                    rolledBack.append(operation.operationID)
                case .rotationPublished, .rotationOldKeyTombstoned, .rotationOldKeyDeleted:
                    try await finishPublishedRotation(operation)
                    completed.append(operation.operationID)
                case .complete, .rolledBack:
                    break
                default:
                    throw corruptCredentialRecord("rotation operation phase")
                }
            case .deletion:
                switch operation.phase {
                case .deletionSlotLocked:
                    try rollbackUnstartedDeletion(operation)
                    rolledBack.append(operation.operationID)
                case .deletionKeyTombstoned, .deletionKeyDeleted:
                    try await finishDeletion(operation)
                    completed.append(operation.operationID)
                case .complete, .rolledBack:
                    break
                default:
                    throw corruptCredentialRecord("deletion operation phase")
                }
            }
        }

        let removedLeaseCount: Int
        if let currentHostProcessEpoch {
            removedLeaseCount = try removeLeasesFromOldEpochs(current: currentHostProcessEpoch)
        } else {
            removedLeaseCount = 0
        }
        return CredentialReconciliationReport(
            abortedCreationOperationIDs: abortedCreations.sorted(),
            completedCreationOperationIDs: completedCreations.sorted(),
            rolledBackOperationIDs: rolledBack.sorted(),
            completedLifecycleOperationIDs: completed.sorted(),
            removedOldEpochLeaseCount: removedLeaseCount
        )
    }

    private func beginRotation(
        credentialRef: String,
        expectedGeneration: UInt64,
        operationID: String
    ) throws -> CredentialLifecycleOperation {
        try database.transaction {
            if let existing = try readLifecycleOperation(operationID) {
                guard existing.kind == .rotation,
                      existing.credentialRef == credentialRef,
                      existing.expectedGeneration == expectedGeneration,
                      existing.nextGeneration == expectedGeneration.addingReportingOverflow(1).partialValue
                else { throw operationConflict() }
                return existing
            }
            let increment = expectedGeneration.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw credentialStoreFailure("credential.generation_overflow", "credential generation overflow")
            }
            guard let slot = try readSlot(credentialRef) else {
                throw credentialStoreFailure("credential.slot_missing", "credential slot does not exist")
            }
            guard slot.lifecycle == .active, slot.currentGeneration == expectedGeneration else {
                throw credentialStoreFailure("credential.generation_conflict", "credential slot generation changed")
            }
            try requireNoCredentialUsers(credentialRef)
            try requireNoCompetingOperation(credentialRef, operationID: operationID)
            let operation = CredentialLifecycleOperation(
                operationID: operationID,
                credentialRef: credentialRef,
                kind: .rotation,
                expectedGeneration: expectedGeneration,
                nextGeneration: increment.partialValue,
                phase: .rotationSlotLocked
            )
            var rotating = slot
            rotating.lifecycle = .rotating(
                operationID: operationID,
                expectedGeneration: expectedGeneration,
                nextGeneration: increment.partialValue
            )
            try persistSlot(
                rotating,
                expectedGeneration: expectedGeneration,
                expectedLifecycle: "active",
                expectedOperationID: nil
            )
            try insertLifecycleOperation(operation)
            return operation
        }
    }

    private func publishRotation(
        _ operation: CredentialLifecycleOperation
    ) throws -> CredentialLifecycleOperation {
        guard operation.kind == .rotation,
              operation.phase == .rotationKeyPromoted,
              let nextGeneration = operation.nextGeneration
        else { throw corruptCredentialRecord("rotation publication") }
        return try database.transaction {
            guard var slot = try readSlot(operation.credentialRef),
                  slot.currentGeneration == operation.expectedGeneration,
                  slot.lifecycle == .rotating(
                    operationID: operation.operationID,
                    expectedGeneration: operation.expectedGeneration,
                    nextGeneration: nextGeneration
                  )
            else { throw credentialStoreFailure("credential.operation_conflict", "rotation slot changed") }
            try requireNoCredentialUsers(operation.credentialRef)
            slot.currentGeneration = nextGeneration
            slot.lifecycle = .active
            try persistSlot(
                slot,
                expectedGeneration: operation.expectedGeneration,
                expectedLifecycle: "rotating",
                expectedOperationID: operation.operationID
            )
            try invalidateGenerationScopedState(
                credentialRef: operation.credentialRef,
                generation: operation.expectedGeneration
            )
            return try advanceLifecycleOperation(operation, to: .rotationPublished)
        }
    }

    private func finishPublishedRotation(
        _ supplied: CredentialLifecycleOperation
    ) async throws {
        var operation = try readLifecycleOperation(supplied.operationID) ?? supplied
        guard operation.kind == .rotation else { throw operationConflict() }
        if operation.phase == .rotationPublished {
            operation = try beginKeyDeletion(
                operation,
                reason: .rotatedGeneration,
                nextPhase: .rotationOldKeyTombstoned
            )
            try faultInjector?(.rotationOldKeyTombstoned)
        }
        if operation.phase == .rotationOldKeyTombstoned {
            try await vault.deleteFinal(
                credentialRef: operation.credentialRef,
                generation: operation.expectedGeneration
            )
            operation = try markKeyDeleted(
                operation,
                nextPhase: .rotationOldKeyDeleted
            )
            try faultInjector?(.rotationOldKeyDeleted)
        }
        if operation.phase == .rotationOldKeyDeleted {
            try completeKeyDeletion(operation, deleteSlot: false)
        }
    }

    private func rollbackUnpublishedRotation(
        _ operation: CredentialLifecycleOperation
    ) async throws {
        guard operation.kind == .rotation,
              [
                .rotationSlotLocked, .rotationStagedWritten,
                .rotationPromotionStarted, .rotationKeyPromoted,
              ].contains(operation.phase),
              let nextGeneration = operation.nextGeneration
        else { throw corruptCredentialRecord("rotation rollback") }
        try await vault.deleteStaged(
            credentialRef: operation.credentialRef,
            generation: nextGeneration,
            operationID: operation.operationID
        )
        if operation.phase == .rotationPromotionStarted || operation.phase == .rotationKeyPromoted {
            try await vault.deleteFinal(
                credentialRef: operation.credentialRef,
                generation: nextGeneration
            )
        }
        try database.transaction {
            guard var slot = try readSlot(operation.credentialRef),
                  slot.currentGeneration == operation.expectedGeneration,
                  slot.lifecycle == .rotating(
                    operationID: operation.operationID,
                    expectedGeneration: operation.expectedGeneration,
                    nextGeneration: nextGeneration
                  )
            else { throw credentialStoreFailure("credential.operation_conflict", "rotation slot changed") }
            slot.lifecycle = .active
            try persistSlot(
                slot,
                expectedGeneration: operation.expectedGeneration,
                expectedLifecycle: "rotating",
                expectedOperationID: operation.operationID
            )
            _ = try advanceLifecycleOperation(operation, to: .rolledBack)
        }
    }

    private func beginDeletion(
        credentialRef: String,
        expectedGeneration: UInt64,
        operationID: String
    ) throws -> CredentialLifecycleOperation {
        try database.transaction {
            if let existing = try readLifecycleOperation(operationID) {
                guard existing.kind == .deletion,
                      existing.credentialRef == credentialRef,
                      existing.expectedGeneration == expectedGeneration,
                      existing.nextGeneration == nil
                else { throw operationConflict() }
                return existing
            }
            guard let slot = try readSlot(credentialRef) else {
                throw credentialStoreFailure("credential.slot_missing", "credential slot does not exist")
            }
            guard slot.lifecycle == .active, slot.currentGeneration == expectedGeneration else {
                throw credentialStoreFailure("credential.generation_conflict", "credential slot generation changed")
            }
            try requireNoCredentialUsers(credentialRef)
            try requireNoCredentialReferences(credentialRef)
            try requireNoCompetingOperation(credentialRef, operationID: operationID)
            let operation = CredentialLifecycleOperation(
                operationID: operationID,
                credentialRef: credentialRef,
                kind: .deletion,
                expectedGeneration: expectedGeneration,
                nextGeneration: nil,
                phase: .deletionSlotLocked
            )
            var deleting = slot
            deleting.lifecycle = .deleting(
                operationID: operationID,
                expectedGeneration: expectedGeneration
            )
            try persistSlot(
                deleting,
                expectedGeneration: expectedGeneration,
                expectedLifecycle: "active",
                expectedOperationID: nil
            )
            try insertLifecycleOperation(operation)
            return operation
        }
    }

    private func finishDeletion(_ supplied: CredentialLifecycleOperation) async throws {
        var operation = try readLifecycleOperation(supplied.operationID) ?? supplied
        guard operation.kind == .deletion else { throw operationConflict() }
        if operation.phase == .deletionSlotLocked {
            operation = try beginKeyDeletion(
                operation,
                reason: .deletedSlot,
                nextPhase: .deletionKeyTombstoned
            )
            try faultInjector?(.deletionKeyTombstoned)
        }
        if operation.phase == .deletionKeyTombstoned {
            try await vault.deleteFinal(
                credentialRef: operation.credentialRef,
                generation: operation.expectedGeneration
            )
            operation = try markKeyDeleted(
                operation,
                nextPhase: .deletionKeyDeleted
            )
            try faultInjector?(.deletionKeyDeleted)
        }
        if operation.phase == .deletionKeyDeleted {
            try completeKeyDeletion(operation, deleteSlot: true)
        }
    }

    private func rollbackUnstartedDeletion(_ operation: CredentialLifecycleOperation) throws {
        guard operation.kind == .deletion, operation.phase == .deletionSlotLocked else {
            throw corruptCredentialRecord("deletion rollback")
        }
        try database.transaction {
            guard var slot = try readSlot(operation.credentialRef),
                  slot.currentGeneration == operation.expectedGeneration,
                  slot.lifecycle == .deleting(
                    operationID: operation.operationID,
                    expectedGeneration: operation.expectedGeneration
                  )
            else { throw credentialStoreFailure("credential.operation_conflict", "deletion slot changed") }
            slot.lifecycle = .active
            try persistSlot(
                slot,
                expectedGeneration: operation.expectedGeneration,
                expectedLifecycle: "deleting",
                expectedOperationID: operation.operationID
            )
            _ = try advanceLifecycleOperation(operation, to: .rolledBack)
        }
    }

    private func beginKeyDeletion(
        _ operation: CredentialLifecycleOperation,
        reason: CredentialKeyTombstoneReason,
        nextPhase: CredentialLifecycleOperationPhase
    ) throws -> CredentialLifecycleOperation {
        try database.transaction {
            let tombstone = CredentialKeyTombstone(
                tombstoneID: keyTombstoneID(operation),
                operationID: operation.operationID,
                credentialRef: operation.credentialRef,
                generation: operation.expectedGeneration,
                reason: reason,
                phase: .deletionStarted
            )
            if let existing = try readKeyTombstone(tombstone.tombstoneID) {
                guard existing == tombstone else { throw operationConflict() }
            } else {
                try database.execute(
                    """
                    INSERT INTO credential_key_tombstones(
                      tombstone_id, credential_ref, generation, phase,
                      record_schema_version, record_json
                    ) VALUES (?1, ?2, ?3, ?4, 2, ?5)
                    """,
                    bindings: [
                        .text(tombstone.tombstoneID), .text(tombstone.credentialRef),
                        .text(String(tombstone.generation)), .text(tombstone.phase.rawValue),
                        .text(try encodeCredentialRecord(VersionedCredentialRecord(tombstone))),
                    ]
                )
            }
            return try advanceLifecycleOperation(operation, to: nextPhase)
        }
    }

    private func markKeyDeleted(
        _ operation: CredentialLifecycleOperation,
        nextPhase: CredentialLifecycleOperationPhase
    ) throws -> CredentialLifecycleOperation {
        try database.transaction {
            let tombstoneID = keyTombstoneID(operation)
            guard var tombstone = try readKeyTombstone(tombstoneID),
                  tombstone.phase == .deletionStarted
            else { throw corruptCredentialRecord("credential key tombstone") }
            tombstone.phase = .keyDeleted
            let changed = try database.executeChanges(
                "UPDATE credential_key_tombstones SET phase = ?1, record_json = ?2 WHERE tombstone_id = ?3 AND phase = ?4",
                bindings: [
                    .text(tombstone.phase.rawValue),
                    .text(try encodeCredentialRecord(VersionedCredentialRecord(tombstone))),
                    .text(tombstoneID), .text(CredentialKeyTombstonePhase.deletionStarted.rawValue),
                ]
            )
            guard changed == 1 else { throw operationConflict() }
            return try advanceLifecycleOperation(operation, to: nextPhase)
        }
    }

    private func completeKeyDeletion(
        _ operation: CredentialLifecycleOperation,
        deleteSlot: Bool
    ) throws {
        try database.transaction {
            let tombstoneID = keyTombstoneID(operation)
            guard var tombstone = try readKeyTombstone(tombstoneID),
                  tombstone.phase == .keyDeleted
            else { throw corruptCredentialRecord("credential key tombstone completion") }
            if deleteSlot {
                let removed = try database.executeChanges(
                    """
                    DELETE FROM credential_slots
                    WHERE credential_ref = ?1 AND current_generation = ?2
                      AND lifecycle = 'deleting' AND operation_id = ?3
                    """,
                    bindings: [
                        .text(operation.credentialRef),
                        .text(String(operation.expectedGeneration)),
                        .text(operation.operationID),
                    ]
                )
                guard removed == 1 else { throw operationConflict() }
            }
            tombstone.phase = .complete
            let changed = try database.executeChanges(
                "UPDATE credential_key_tombstones SET phase = 'complete', record_json = ?1 WHERE tombstone_id = ?2 AND phase = 'key_deleted'",
                bindings: [
                    .text(try encodeCredentialRecord(VersionedCredentialRecord(tombstone))),
                    .text(tombstoneID),
                ]
            )
            guard changed == 1 else { throw operationConflict() }
            _ = try advanceLifecycleOperation(operation, to: .complete)
        }
    }

    private func abortUnpublishedCreation(_ operation: CredentialCreationOperation) throws {
        try database.transaction {
            guard try readSlot(operation.credentialRef) == nil else {
                throw corruptCredentialRecord("unpublished creation with slot")
            }
            let removed = try database.executeChanges(
                "DELETE FROM credential_creation_operations WHERE operation_id = ?1 AND credential_ref = ?2 AND generation = ?3 AND phase = ?4",
                bindings: [
                    .text(operation.operationID), .text(operation.credentialRef),
                    .text(String(operation.generation)), .text(operation.phase.rawValue),
                ]
            )
            guard removed == 1 else { throw operationConflict() }
        }
    }

    private func persistSlot(
        _ slot: CredentialSlotState,
        expectedGeneration: UInt64,
        expectedLifecycle: String,
        expectedOperationID: String?
    ) throws {
        var sql = """
        UPDATE credential_slots SET current_generation = ?1, lifecycle = ?2,
          operation_id = ?3, record_json = ?4
        WHERE credential_ref = ?5 AND current_generation = ?6 AND lifecycle = ?7
        """
        var bindings: [SQLiteValue] = [
            .text(String(slot.currentGeneration)), .text(slot.lifecycle.indexValue),
            slot.lifecycle.operationID.map(SQLiteValue.text) ?? .null,
            .text(try encodeCredentialRecord(VersionedCredentialRecord(slot))),
            .text(slot.credentialRef), .text(String(expectedGeneration)),
            .text(expectedLifecycle),
        ]
        if let expectedOperationID {
            sql += " AND operation_id = ?8"
            bindings.append(.text(expectedOperationID))
        } else {
            sql += " AND operation_id IS NULL"
        }
        guard try database.executeChanges(sql, bindings: bindings) == 1 else {
            throw credentialStoreFailure("credential.operation_conflict", "credential slot changed")
        }
    }

    private func insertLifecycleOperation(_ operation: CredentialLifecycleOperation) throws {
        try database.execute(
            """
            INSERT INTO credential_operation_tombstones(
              operation_id, credential_ref, operation_kind, phase,
              record_schema_version, record_json
            ) VALUES (?1, ?2, ?3, ?4, 2, ?5)
            """,
            bindings: [
                .text(operation.operationID), .text(operation.credentialRef),
                .text(operation.kind.rawValue), .text(operation.phase.rawValue),
                .text(try encodeCredentialRecord(VersionedCredentialRecord(operation))),
            ]
        )
    }

    private func advanceLifecycleOperation(
        _ operation: CredentialLifecycleOperation,
        to phase: CredentialLifecycleOperationPhase
    ) throws -> CredentialLifecycleOperation {
        var updated = operation
        updated.phase = phase
        let changed = try database.executeChanges(
            """
            UPDATE credential_operation_tombstones SET phase = ?1, record_json = ?2
            WHERE operation_id = ?3 AND credential_ref = ?4
              AND operation_kind = ?5 AND phase = ?6
            """,
            bindings: [
                .text(phase.rawValue),
                .text(try encodeCredentialRecord(VersionedCredentialRecord(updated))),
                .text(operation.operationID), .text(operation.credentialRef),
                .text(operation.kind.rawValue), .text(operation.phase.rawValue),
            ]
        )
        guard changed == 1 else { throw operationConflict() }
        return updated
    }

    nonisolated private func readLifecycleOperation(
        _ operationID: String
    ) throws -> CredentialLifecycleOperation? {
        let rows = try database.queryRows(
            "SELECT operation_id, credential_ref, operation_kind, phase, record_schema_version, record_json FROM credential_operation_tombstones WHERE operation_id = ?1",
            bindings: [.text(operationID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptCredentialRecord("credential lifecycle operation") }
        let value = try decodeCredentialRecord(
            VersionedCredentialRecord<CredentialLifecycleOperation>.self,
            json: json
        ).value
        guard row.text("operation_id") == value.operationID,
              row.text("credential_ref") == value.credentialRef,
              row.text("operation_kind") == value.kind.rawValue,
              row.text("phase") == value.phase.rawValue,
              validLifecyclePhase(value)
        else { throw corruptCredentialRecord("credential lifecycle operation index") }
        return value
    }

    nonisolated private func readKeyTombstone(
        _ tombstoneID: String
    ) throws -> CredentialKeyTombstone? {
        let rows = try database.queryRows(
            "SELECT tombstone_id, credential_ref, generation, phase, record_schema_version, record_json FROM credential_key_tombstones WHERE tombstone_id = ?1",
            bindings: [.text(tombstoneID)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row.integer("record_schema_version") == 2,
              let json = row.text("record_json")
        else { throw corruptCredentialRecord("credential key tombstone") }
        let value = try decodeCredentialRecord(
            VersionedCredentialRecord<CredentialKeyTombstone>.self,
            json: json
        ).value
        guard row.text("tombstone_id") == value.tombstoneID,
              row.text("credential_ref") == value.credentialRef,
              row.text("generation") == String(value.generation),
              row.text("phase") == value.phase.rawValue
        else { throw corruptCredentialRecord("credential key tombstone index") }
        return value
    }

    private func allCreationOperations() throws -> [CredentialCreationOperation] {
        try database.queryRows(
            "SELECT operation_id FROM credential_creation_operations ORDER BY operation_id"
        ).map { row in
            guard let operationID = row.text("operation_id"),
                  let operation = try readOperation(operationID)
            else { throw corruptCredentialRecord("creation operation list") }
            return operation
        }
    }

    private func allLifecycleOperations() throws -> [CredentialLifecycleOperation] {
        try database.queryRows(
            "SELECT operation_id FROM credential_operation_tombstones ORDER BY operation_id"
        ).map { row in
            guard let operationID = row.text("operation_id"),
                  let operation = try readLifecycleOperation(operationID)
            else { throw corruptCredentialRecord("lifecycle operation list") }
            return operation
        }
    }

    private func requireNoCredentialUsers(_ credentialRef: String) throws {
        let count = try database.queryRows(
            "SELECT COUNT(*) AS value FROM credential_use_leases WHERE credential_ref = ?1",
            bindings: [.text(credentialRef)]
        ).first?.integer("value") ?? 0
        guard count == 0 else {
            throw credentialStoreFailure("credential.in_use", "credential generation has active users")
        }
    }

    private func requireNoCompetingOperation(
        _ credentialRef: String,
        operationID: String
    ) throws {
        let rows = try database.queryRows(
            """
            SELECT operation_id FROM credential_operation_tombstones
            WHERE credential_ref = ?1 AND operation_id <> ?2
              AND phase NOT IN ('complete', 'rolled_back')
            """,
            bindings: [.text(credentialRef), .text(operationID)]
        )
        guard rows.isEmpty else { throw operationConflict() }
    }

    private func requireNoCredentialReferences(_ credentialRef: String) throws {
        let activeProfiles = try database.queryRows(
            "SELECT profile_id FROM provider_profile_revisions WHERE credential_ref = ?1 AND lifecycle <> 'archived' LIMIT 1",
            bindings: [.text(credentialRef)]
        )
        guard activeProfiles.isEmpty else {
            throw credentialStoreFailure("credential.referenced", "credential is referenced by an active provider profile")
        }
        guard try !hasPendingBindingReference(credentialRef) else {
            throw credentialStoreFailure("credential.binding_pending", "credential is referenced by a pending host binding")
        }
        for table in ["prepared_cloud_sessions", "sanitized_llm_snapshots"] {
            for row in try database.queryRows("SELECT record_json FROM \(table)") {
                guard let json = row.text("record_json") else {
                    throw corruptCredentialRecord("retained credential reference")
                }
                if jsonContainsCredentialReference(json, credentialRef: credentialRef) {
                    throw credentialStoreFailure(
                        "credential.snapshot_retained",
                        "credential is referenced by retained cloud state"
                    )
                }
            }
        }
    }

    private func hasPendingBindingReference(_ credentialRef: String) throws -> Bool {
        for row in try database.queryRows(
            "SELECT record_json FROM host_bindings WHERE state = 'staged'"
        ) {
            guard let json = row.text("record_json") else {
                throw corruptCredentialRecord("host binding reference")
            }
            let reference: CredentialBindingReference
            do {
                reference = try JSONDecoder().decode(
                    CredentialBindingReference.self,
                    from: Data(json.utf8)
                )
            } catch {
                throw corruptCredentialRecord("host binding reference")
            }
            let targetRows = try database.queryRows(
                """
                SELECT p.credential_ref
                FROM llm_target_revisions AS t
                JOIN provider_profile_revisions AS p
                  ON p.profile_id = t.profile_id AND p.revision = t.profile_revision
                WHERE t.target_id = ?1 AND t.revision = ?2
                """,
                bindings: [
                    .text(reference.request.configuration.llmTargetID.rawValue),
                    .text(String(reference.request.configuration.llmTargetRevision)),
                ]
            )
            if targetRows.contains(where: { $0.text("credential_ref") == credentialRef }) {
                return true
            }
        }
        return false
    }

    private func invalidateGenerationScopedState(
        credentialRef: String,
        generation: UInt64
    ) throws {
        let generationValue = String(generation)
        try database.execute(
            """
            DELETE FROM egress_generation_authorizations
            WHERE credential_generation = ?1 AND grant_id IN (
              SELECT g.grant_id
              FROM egress_scope_grants AS g
              JOIN provider_profile_revisions AS p
                ON p.profile_id = g.profile_id AND p.revision = g.profile_revision
              WHERE p.credential_ref = ?2 AND g.credential_generation = ?1
            )
            """,
            bindings: [.text(generationValue), .text(credentialRef)]
        )
        try database.execute(
            """
            DELETE FROM egress_scope_grants
            WHERE credential_generation = ?1 AND EXISTS (
              SELECT 1 FROM provider_profile_revisions AS p
              WHERE p.profile_id = egress_scope_grants.profile_id
                AND p.revision = egress_scope_grants.profile_revision
                AND p.credential_ref = ?2
            )
            """,
            bindings: [.text(generationValue), .text(credentialRef)]
        )
        try database.execute(
            """
            DELETE FROM provider_validation_records
            WHERE credential_generation = ?1 AND EXISTS (
              SELECT 1 FROM provider_profile_revisions AS p
              WHERE p.profile_id = provider_validation_records.profile_id
                AND p.revision = provider_validation_records.profile_revision
                AND p.credential_ref = ?2
            )
            """,
            bindings: [.text(generationValue), .text(credentialRef)]
        )
        try database.execute(
            """
            DELETE FROM cloud_capability_observations
            WHERE credential_generation = ?1 AND EXISTS (
              SELECT 1 FROM provider_profile_revisions AS p
              WHERE p.profile_id = cloud_capability_observations.profile_id
                AND p.revision = cloud_capability_observations.profile_revision
                AND p.credential_ref = ?2
            )
            """,
            bindings: [.text(generationValue), .text(credentialRef)]
        )

        let stateRows = try database.queryRows(
            """
            SELECT s.profile_id, s.profile_revision, s.state_revision, s.record_json
            FROM provider_profile_state AS s
            JOIN provider_profile_revisions AS p
              ON p.profile_id = s.profile_id AND p.revision = s.profile_revision
            WHERE p.credential_ref = ?1
            """,
            bindings: [.text(credentialRef)]
        )
        for row in stateRows {
            guard let profileID = row.text("profile_id"),
                  let profileRevision = row.text("profile_revision"),
                  let stateRevision = row.text("state_revision"),
                  let json = row.text("record_json")
            else { throw corruptCredentialRecord("provider readiness state") }
            var persisted = try decodeCredentialRecord(PersistedProfileState.self, json: json)
            guard persisted.state.profileID == profileID,
                  String(persisted.state.profileRevision) == profileRevision,
                  String(persisted.state.stateRevision) == stateRevision,
                  persisted.state.stateRevision < UInt64.max
            else { throw corruptCredentialRecord("provider readiness state index") }
            persisted.state.validationState = .invalidated(reasonCode: "credential.rotated")
            persisted.state.catalogRevision = nil
            persisted.state.stateRevision += 1
            let changed = try database.executeChanges(
                """
                UPDATE provider_profile_state SET catalog_revision = NULL,
                  state_revision = ?1, record_json = ?2
                WHERE profile_id = ?3 AND profile_revision = ?4 AND state_revision = ?5
                """,
                bindings: [
                    .text(String(persisted.state.stateRevision)),
                    .text(try encodeCredentialRecord(persisted)),
                    .text(profileID), .text(profileRevision), .text(stateRevision),
                ]
            )
            guard changed == 1 else { throw operationConflict() }
        }
    }

    nonisolated func validatePersistedLifecycleRecords() throws {
        for row in try database.queryRows(
            "SELECT operation_id FROM credential_operation_tombstones"
        ) {
            guard let operationID = row.text("operation_id") else {
                throw corruptCredentialRecord("credential lifecycle operation")
            }
            _ = try readLifecycleOperation(operationID)
        }
        for row in try database.queryRows(
            "SELECT tombstone_id FROM credential_key_tombstones"
        ) {
            guard let tombstoneID = row.text("tombstone_id") else {
                throw corruptCredentialRecord("credential key tombstone")
            }
            _ = try readKeyTombstone(tombstoneID)
        }
    }
}

private struct CredentialBindingReference: Decodable {
    struct Request: Decodable {
        let configuration: AgentHostConfiguration
    }

    let request: Request
}

private func keyTombstoneID(_ operation: CredentialLifecycleOperation) -> String {
    "\(operation.kind.rawValue)/\(operation.operationID)/\(operation.expectedGeneration)"
}

private func validLifecyclePhase(_ operation: CredentialLifecycleOperation) -> Bool {
    switch operation.kind {
    case .rotation:
        return operation.nextGeneration != nil && [
            .rotationSlotLocked, .rotationStagedWritten, .rotationPromotionStarted,
            .rotationKeyPromoted, .rotationPublished,
            .rotationOldKeyTombstoned, .rotationOldKeyDeleted, .complete, .rolledBack,
        ].contains(operation.phase)
    case .deletion:
        return operation.nextGeneration == nil && [
            .deletionSlotLocked, .deletionKeyTombstoned, .deletionKeyDeleted,
            .complete, .rolledBack,
        ].contains(operation.phase)
    }
}

private func jsonContainsCredentialReference(_ json: String, credentialRef: String) -> Bool {
    guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
        return true
    }
    return containsCredentialReference(value, credentialRef: credentialRef)
}

private func containsCredentialReference(_ value: Any, credentialRef: String) -> Bool {
    if let object = value as? [String: Any] {
        if object["credential_ref"] as? String == credentialRef
            || object["credentialRef"] as? String == credentialRef {
            return true
        }
        return object.values.contains { containsCredentialReference($0, credentialRef: credentialRef) }
    }
    if let array = value as? [Any] {
        return array.contains { containsCredentialReference($0, credentialRef: credentialRef) }
    }
    return false
}

private func operationConflict() -> CredentialFailure {
    credentialStoreFailure("credential.operation_conflict", "credential lifecycle operation changed")
}
