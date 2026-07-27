import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Generation-pinned cloud credentials")
struct ProviderCredentialStoreTests {
    @Test
    func initialPublicationIsTrackedAndExactlyIdempotent() async throws {
        let harness = try credentialHarness()
        let secret = SecretBytes(utf8: "fixture-secret")

        try await harness.store.createSlot(
            credentialRef: "shared-key",
            initialSecret: secret,
            operationID: "create-1"
        )

        #expect(try await harness.store.operation("create-1")?.phase == .complete)
        #expect(try await harness.store.slot("shared-key") == CredentialSlotState(
            credentialRef: "shared-key",
            currentGeneration: 1,
            lifecycle: .active
        ))
        #expect(await harness.vault.events == [
            .write(CredentialVaultAccount.staged(
                credentialRef: "shared-key",
                generation: 1,
                operationID: "create-1"
            )),
            .promote(
                from: CredentialVaultAccount.staged(
                    credentialRef: "shared-key",
                    generation: 1,
                    operationID: "create-1"
                ),
                to: CredentialVaultAccount.final(
                    credentialRef: "shared-key",
                    generation: 1
                )
            ),
        ])

        try await harness.store.createSlot(
            credentialRef: "shared-key",
            initialSecret: SecretBytes(utf8: "fixture-secret"),
            operationID: "create-1"
        )
        #expect(await harness.vault.events.count == 2)
        await expectCredentialFailure("credential.operation_conflict") {
            try await harness.store.createSlot(
                credentialRef: "other-key",
                initialSecret: SecretBytes(utf8: "other"),
                operationID: "create-1"
            )
        }
    }

    @Test
    func creatingSlotRejectsLeaseAndNewProfileReference() async throws {
        let directory = temporaryCredentialDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        _ = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        let vault = RecordingCredentialVault(failPromotion: true)
        let credentials = try ProviderCredentialStore(fileURL: url, vault: vault)

        await expectCredentialFailure("credential.vault_injected") {
            try await credentials.createSlot(
                credentialRef: "creating-key",
                initialSecret: SecretBytes(utf8: "fixture-secret"),
                operationID: "create-interrupted"
            )
        }
        #expect(try await credentials.slot("creating-key")?.lifecycle == .creating(
            operationID: "create-interrupted",
            generation: 1
        ))
        await expectCredentialFailure("credential.slot_not_active") {
            try await credentials.acquireUseLease(
                credentialRef: "creating-key",
                purpose: .validation,
                preparationID: nil,
                hostProcessEpoch: try HostProcessEpoch.generate()
            )
        }

        let profiles = try ProviderProfileStore(
            fileURL: url,
            originValidator: FixtureOriginValidator()
        )
        await expectProfileFailure("provider_profile.credential_not_active") {
            try await profiles.publish(ProviderProfileRevision(
                profileID: "profile-creating",
                revision: 1,
                presetID: .openAI,
                displayName: "Creating",
                baseURL: URL(string: "https://api.openai.com/v1")!,
                credentialRef: "creating-key"
            ))
        }
    }

    @Test
    func leasePinsGenerationAndCredentialResolutionRechecksAuthority() async throws {
        let harness = try credentialHarness()
        try await createActiveSlot(harness)
        let epoch = try HostProcessEpoch.generate()

        let lease = try await harness.store.acquireUseLease(
            credentialRef: "shared-key",
            purpose: .preparation,
            preparationID: "prep-1",
            hostProcessEpoch: epoch
        )

        #expect(lease.generation == 1)
        #expect(try await harness.store.slot("shared-key")?.currentGeneration == 1)
        let resolved = try await harness.store.withCredential(for: lease.leaseID) { secret in
            String(decoding: secret.dataCopyForVault(), as: UTF8.self)
        }
        #expect(resolved == "fixture-secret")

        await harness.vault.removeFinal(credentialRef: "shared-key", generation: 1)
        await expectCredentialFailure("credential.missing") {
            try await harness.store.withCredential(for: lease.leaseID) { _ in true }
        }
    }

    @Test
    func validationAndPreparationLeasesHaveExactLifecycles() async throws {
        let harness = try credentialHarness()
        try await createActiveSlot(harness)
        let epoch = try HostProcessEpoch.generate()
        let validation = try await harness.store.acquireUseLease(
            credentialRef: "shared-key",
            purpose: .validation,
            preparationID: nil,
            hostProcessEpoch: epoch
        )
        try await harness.store.releaseValidationLease(validation.leaseID)
        #expect(try await harness.store.lease(validation.leaseID) == nil)

        let preparation = try await harness.store.acquireUseLease(
            credentialRef: "shared-key",
            purpose: .preparation,
            preparationID: "prep-1",
            hostProcessEpoch: epoch
        )
        let bound = try await harness.store.bindPreparationLease(
            preparation.leaseID,
            expectedRevision: preparation.revision
        )
        #expect(bound.lifecycle == .sessionBound)
        #expect(bound.revision == 2)
        let closing = try await harness.store.beginClosingLease(
            preparation.leaseID,
            expectedRevision: bound.revision
        )
        #expect(closing.lifecycle == .closing)
        try await harness.store.closeLease(
            preparation.leaseID,
            expectedRevision: closing.revision
        )
        #expect(try await harness.store.lease(preparation.leaseID) == nil)
    }

    @Test
    func oldEpochCleanupDoesNotRemoveCurrentEpochLease() async throws {
        let harness = try credentialHarness()
        try await createActiveSlot(harness)
        let oldEpoch = try HostProcessEpoch.generate()
        let currentEpoch = try HostProcessEpoch.generate()
        let old = try await harness.store.acquireUseLease(
            credentialRef: "shared-key",
            purpose: .validation,
            preparationID: nil,
            hostProcessEpoch: oldEpoch
        )
        let current = try await harness.store.acquireUseLease(
            credentialRef: "shared-key",
            purpose: .validation,
            preparationID: nil,
            hostProcessEpoch: currentEpoch
        )

        #expect(try await harness.store.removeLeasesFromOldEpochs(current: currentEpoch) == 1)
        #expect(try await harness.store.lease(old.leaseID) == nil)
        #expect(try await harness.store.lease(current.leaseID) == current)
    }

    @Test
    func rotatingAndDeletingSlotsRejectNewUseLeases() async throws {
        let harness = try credentialHarness()
        try await createActiveSlot(harness)
        let epoch = try HostProcessEpoch.generate()

        try await harness.store.replaceSlotLifecycleForTesting(
            credentialRef: "shared-key",
            lifecycle: .rotating(
                operationID: "rotate-1",
                expectedGeneration: 1,
                nextGeneration: 2
            )
        )
        await expectCredentialFailure("credential.slot_not_active") {
            try await harness.store.acquireUseLease(
                credentialRef: "shared-key",
                purpose: .validation,
                preparationID: nil,
                hostProcessEpoch: epoch
            )
        }

        try await harness.store.replaceSlotLifecycleForTesting(
            credentialRef: "shared-key",
            lifecycle: .deleting(operationID: "delete-1", expectedGeneration: 1)
        )
        await expectCredentialFailure("credential.slot_not_active") {
            try await harness.store.acquireUseLease(
                credentialRef: "shared-key",
                purpose: .validation,
                preparationID: nil,
                hostProcessEpoch: epoch
            )
        }
    }

    @Test
    func concurrentAcquisitionPinsOneGenerationAndUniqueLeaseIDs() async throws {
        let harness = try credentialHarness()
        try await createActiveSlot(harness)
        let epoch = try HostProcessEpoch.generate()

        let leases = try await withThrowingTaskGroup(of: CredentialUseLease.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await harness.store.acquireUseLease(
                        credentialRef: "shared-key",
                        purpose: .validation,
                        preparationID: nil,
                        hostProcessEpoch: epoch
                    )
                }
            }
            var result: [CredentialUseLease] = []
            for try await lease in group { result.append(lease) }
            return result
        }

        #expect(Set(leases.map(\.leaseID)).count == 20)
        #expect(leases.allSatisfy { $0.generation == 1 })
    }

    @Test
    func persistedCredentialRecordsNeverContainSecretBytes() async throws {
        let harness = try credentialHarness()
        let sentinel = "fixture-secret-never-in-sqlite"
        try await harness.store.createSlot(
            credentialRef: "shared-key",
            initialSecret: SecretBytes(utf8: sentinel),
            operationID: "create-1"
        )
        _ = try await harness.store.acquireUseLease(
            credentialRef: "shared-key",
            purpose: .validation,
            preparationID: nil,
            hostProcessEpoch: try HostProcessEpoch.generate()
        )

        #expect(await harness.store.persistedTextValuesForTesting().allSatisfy {
            !$0.contains(sentinel)
        })
    }
}

private struct CredentialHarness: Sendable {
    let store: ProviderCredentialStore
    let vault: RecordingCredentialVault
}

private func credentialHarness() throws -> CredentialHarness {
    let connection = try SQLiteConnection(path: ":memory:")
    try LLMStoreSchema.ensureBaseSchema(connection)
    try LLMStoreSchema.migrateToCurrent(connection)
    let vault = RecordingCredentialVault()
    return CredentialHarness(
        store: try ProviderCredentialStore(database: connection, vault: vault),
        vault: vault
    )
}

private func createActiveSlot(_ harness: CredentialHarness) async throws {
    try await harness.store.createSlot(
        credentialRef: "shared-key",
        initialSecret: SecretBytes(utf8: "fixture-secret"),
        operationID: "create-1"
    )
}

private actor RecordingCredentialVault: CredentialVault {
    enum Event: Equatable, Sendable {
        case write(String)
        case promote(from: String, to: String)
    }

    private(set) var events: [Event] = []
    private var values: [String: Data] = [:]
    private let failPromotion: Bool

    init(failPromotion: Bool = false) {
        self.failPromotion = failPromotion
    }

    package func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws {
        let account = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        let data = secret.dataCopyForVault()
        if let existing = values[account], existing != data {
            throw CredentialFailure(
                code: "credential.operation_conflict",
                message: "staged credential differs"
            )
        }
        if values[account] == nil {
            values[account] = data
            events.append(.write(account))
        }
    }

    package func promoteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        if failPromotion {
            throw CredentialFailure(
                code: "credential.vault_injected",
                message: "injected promotion failure"
            )
        }
        let staged = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        let final = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )
        if values[final] != nil, values[staged] == nil { return }
        guard let value = values.removeValue(forKey: staged) else {
            throw CredentialFailure(code: "credential.missing", message: "staged item missing")
        }
        values[final] = value
        events.append(.promote(from: staged, to: final))
    }

    package func loadFinal(
        credentialRef: String,
        generation: UInt64
    ) async throws -> SecretBytes {
        let account = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )
        guard let value = values[account] else {
            throw CredentialFailure(code: "credential.missing", message: "final item missing")
        }
        return SecretBytes(bytes: value)
    }

    package func finalExists(credentialRef: String, generation: UInt64) async throws -> Bool {
        values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] != nil
    }

    package func deleteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
        values.removeValue(forKey: CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        ))
    }

    package func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        values.removeValue(forKey: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }

    func removeFinal(credentialRef: String, generation: UInt64) {
        values.removeValue(forKey: CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        ))
    }
}

private func expectCredentialFailure<T>(
    _ code: String,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected CredentialFailure with code \(code)")
    } catch let failure as CredentialFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func expectProfileFailure<T>(
    _ code: String,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("expected ProviderProfileFailure with code \(code)")
    } catch let failure as ProviderProfileFailure {
        #expect(failure.code == code)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func temporaryCredentialDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "provider-credential-store-\(UUID().uuidString)",
        isDirectory: true
    )
}
