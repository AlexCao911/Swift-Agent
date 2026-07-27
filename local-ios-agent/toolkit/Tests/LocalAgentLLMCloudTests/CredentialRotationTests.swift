import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMCloud

@Suite("Credential rotation serialization")
struct CredentialRotationTests {
    @Test
    func rotationAndLeaseAcquisitionHaveExactlyOneWinner() async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        let epoch = try HostProcessEpoch.generate()

        async let lease = captureCredentialOutcome {
            try await harness.store.acquireUseLease(
                credentialRef: "shared",
                purpose: .preparation,
                preparationID: "prep-race",
                hostProcessEpoch: epoch
            )
        }
        async let rotation = captureCredentialOutcome {
            try await harness.store.rotateCredential(
                credentialRef: "shared",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "replacement"),
                operationID: "rotate-race"
            )
        }

        let outcomes = await [lease, rotation]
        #expect(outcomes.filter(\.succeeded).count == 1)
        #expect(outcomes.filter { !$0.succeeded }.count == 1)
    }

    @Test(arguments: [CredentialUseLifecycle.acquired, .sessionBound, .closing])
    func everyPreparationLeaseLifecycleBlocksRotation(
        lifecycle: CredentialUseLifecycle
    ) async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        let acquired = try await harness.store.acquireUseLease(
            credentialRef: "shared",
            purpose: .preparation,
            preparationID: "prep-1",
            hostProcessEpoch: try HostProcessEpoch.generate()
        )
        if lifecycle == .sessionBound || lifecycle == .closing {
            let bound = try await harness.store.bindPreparationLease(
                acquired.leaseID,
                expectedRevision: acquired.revision
            )
            if lifecycle == .closing {
                _ = try await harness.store.beginClosingLease(
                    bound.leaseID,
                    expectedRevision: bound.revision
                )
            }
        }

        await expectLifecycleFailure("credential.in_use") {
            try await harness.store.rotateCredential(
                credentialRef: "shared",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "replacement"),
                operationID: "rotate-blocked"
            )
        }
        #expect(try await harness.store.slot("shared")?.currentGeneration == 1)
    }

    @Test
    func successfulRotationAdvancesGenerationAndInvalidatesSharedState() async throws {
        let directory = temporaryLifecycleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")
        let profiles = try ProviderProfileStore(
            fileURL: url,
            originValidator: LifecycleOriginValidator()
        )
        let vault = LifecycleCredentialVault()
        let store = try ProviderCredentialStore(fileURL: url, vault: vault)
        try await store.createSlot(
            credentialRef: "shared",
            initialSecret: SecretBytes(utf8: "original"),
            operationID: "create"
        )
        try await store.createSlot(
            credentialRef: "other",
            initialSecret: SecretBytes(utf8: "unrelated"),
            operationID: "create-other"
        )
        for profileID in ["profile-a", "profile-b"] {
            _ = try await profiles.publish(lifecycleProfile(profileID: profileID))
            let state = try #require(await profiles.state(profileID: profileID, profileRevision: 1))
            _ = try await profiles.updateState(
                profileID: profileID,
                profileRevision: 1,
                expectedStateRevision: state.stateRevision
            ) { value in
                value.catalogRevision = 7
            }
        }
        _ = try await profiles.publish(lifecycleProfile(
            profileID: "profile-unrelated",
            credentialRef: "other"
        ))
        let database = try SQLiteConnection(path: url.path)
        try seedGenerationScopedRows(
            database,
            profileID: "profile-a",
            generation: 1,
            prefix: "shared"
        )
        try seedGenerationScopedRows(
            database,
            profileID: "profile-unrelated",
            generation: 1,
            prefix: "unrelated"
        )

        try await store.rotateCredential(
            credentialRef: "shared",
            expectedGeneration: 1,
            replacement: SecretBytes(utf8: "replacement"),
            operationID: "rotate"
        )

        #expect(try await store.slot("shared") == CredentialSlotState(
            credentialRef: "shared",
            currentGeneration: 2,
            lifecycle: .active
        ))
        let vaultAccounts = await vault.accountNames()
        #expect(
            await vault.hasFinal(credentialRef: "shared", generation: 2),
            "vault accounts: \(vaultAccounts)"
        )
        #expect(!(await vault.hasFinal(credentialRef: "shared", generation: 1)))
        for table in [
            "provider_validation_records",
            "cloud_capability_observations",
            "egress_scope_grants",
            "egress_generation_authorizations",
        ] {
            #expect(try database.queryRows("SELECT * FROM \(table)").count == 1)
        }
        for profileID in ["profile-a", "profile-b"] {
            let state = try #require(await profiles.state(profileID: profileID, profileRevision: 1))
            #expect(state.validationState == .invalidated(reasonCode: "credential.rotated"))
            #expect(state.catalogRevision == nil)
        }
    }

    @Test
    func completedRotationIsIdempotentAndConflictingReplayIsRejected() async throws {
        let harness = try lifecycleHarness()
        try await harness.createActiveSlot()
        try await harness.store.rotateCredential(
            credentialRef: "shared",
            expectedGeneration: 1,
            replacement: SecretBytes(utf8: "replacement"),
            operationID: "rotate"
        )
        try await harness.store.rotateCredential(
            credentialRef: "shared",
            expectedGeneration: 1,
            replacement: SecretBytes(utf8: "replacement"),
            operationID: "rotate"
        )
        #expect(try await harness.store.slot("shared")?.currentGeneration == 2)

        await expectLifecycleFailure("credential.operation_conflict") {
            try await harness.store.rotateCredential(
                credentialRef: "other",
                expectedGeneration: 1,
                replacement: SecretBytes(utf8: "other"),
                operationID: "rotate"
            )
        }
    }
}

struct LifecycleOutcome: Sendable {
    let succeeded: Bool
    let code: String?
}

func captureCredentialOutcome<T: Sendable>(
    _ operation: @Sendable () async throws -> T
) async -> LifecycleOutcome {
    do {
        _ = try await operation()
        return LifecycleOutcome(succeeded: true, code: nil)
    } catch let failure as CredentialFailure {
        return LifecycleOutcome(succeeded: false, code: failure.code)
    } catch {
        return LifecycleOutcome(succeeded: false, code: String(describing: error))
    }
}

struct LifecycleHarness: Sendable {
    let database: SQLiteConnection
    let vault: LifecycleCredentialVault
    let faults: LifecycleFaultInjector
    let store: ProviderCredentialStore

    func createActiveSlot() async throws {
        try await store.createSlot(
            credentialRef: "shared",
            initialSecret: SecretBytes(utf8: "original"),
            operationID: "create"
        )
    }
}

func lifecycleHarness() throws -> LifecycleHarness {
    let database = try SQLiteConnection(path: ":memory:")
    try LLMStoreSchema.ensureBaseSchema(database)
    try LLMStoreSchema.migrateToCurrent(database)
    let vault = LifecycleCredentialVault()
    let faults = LifecycleFaultInjector()
    return LifecycleHarness(
        database: database,
        vault: vault,
        faults: faults,
        store: try ProviderCredentialStore(
            database: database,
            vault: vault,
            faultInjector: faults.hit
        )
    )
}

final class LifecycleFaultInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var armed: CredentialLifecycleCheckpoint?

    func arm(_ checkpoint: CredentialLifecycleCheckpoint?) {
        lock.withLock { armed = checkpoint }
    }

    func hit(_ checkpoint: CredentialLifecycleCheckpoint) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard armed == checkpoint else { return false }
            armed = nil
            return true
        }
        if shouldThrow {
            throw CredentialFailure(code: "credential.injected_crash", message: checkpoint.rawValue)
        }
    }
}

actor LifecycleCredentialVault: CredentialVault {
    private var values: [String: Data] = [:]
    private var failNextStagedWrite = false
    private(set) var deletedAccounts: [String] = []

    func setFailNextStagedWrite() { failNextStagedWrite = true }

    package func writeStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        secret: SecretBytes
    ) async throws {
        if failNextStagedWrite {
            failNextStagedWrite = false
            throw CredentialFailure(code: "credential.vault_injected", message: "staged write failed")
        }
        let account = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        let data = secret.dataCopyForVault()
        if let existing = values[account], existing != data {
            throw CredentialFailure(code: "credential.operation_conflict", message: "staged value differs")
        }
        values[account] = data
    }

    package func promoteStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String
    ) async throws {
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
        if values[final] != nil, values[staged] != nil {
            throw CredentialFailure(
                code: "credential.operation_conflict",
                message: "promotion identities are ambiguous"
            )
        }
        guard let value = values.removeValue(forKey: staged) else {
            throw CredentialFailure(code: "credential.missing", message: "staged item missing")
        }
        values[final] = value
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
        let account = CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )
        values.removeValue(forKey: account)
        deletedAccounts.append(account)
    }

    package func deleteFinal(credentialRef: String, generation: UInt64) async throws {
        let account = CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )
        values.removeValue(forKey: account)
        deletedAccounts.append(account)
    }

    func hasFinal(credentialRef: String, generation: UInt64) -> Bool {
        values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] != nil
    }

    func accountNames() -> [String] { values.keys.sorted() }

    func hasStaged(credentialRef: String, generation: UInt64, operationID: String) -> Bool {
        values[CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )] != nil
    }

    func seedStaged(
        credentialRef: String,
        generation: UInt64,
        operationID: String,
        value: String
    ) {
        values[CredentialVaultAccount.staged(
            credentialRef: credentialRef,
            generation: generation,
            operationID: operationID
        )] = Data(value.utf8)
    }

    func seedFinal(credentialRef: String, generation: UInt64, value: String) {
        values[CredentialVaultAccount.final(
            credentialRef: credentialRef,
            generation: generation
        )] = Data(value.utf8)
    }
}

struct LifecycleOriginValidator: ProviderOriginValidating {
    func validate(_ baseURL: URL) async throws -> EgressOrigin {
        EgressOrigin(scheme: "https", host: baseURL.host ?? "invalid", port: 443)
    }
}

func lifecycleProfile(profileID: String, credentialRef: String = "shared") -> ProviderProfileRevision {
    ProviderProfileRevision(
        profileID: profileID,
        revision: 1,
        presetID: .openAI,
        displayName: profileID,
        baseURL: URL(string: "https://api.openai.com/v1")!,
        credentialRef: credentialRef
    )
}

func seedGenerationScopedRows(
    _ database: SQLiteConnection,
    profileID: String,
    generation: UInt64,
    prefix: String
) throws {
    let value = String(generation)
    try database.execute(
        "INSERT INTO provider_validation_records VALUES (?1, ?2, '1', 'model', ?3, '2099', 2, '{}')",
        bindings: [.text("\(prefix)-validation"), .text(profileID), .text(value)]
    )
    try database.execute(
        "INSERT INTO cloud_capability_observations VALUES (?1, ?2, '1', 'model', ?3, '2099', 2, '{}')",
        bindings: [.text("\(prefix)-observation"), .text(profileID), .text(value)]
    )
    try database.execute(
        "INSERT INTO egress_scope_grants VALUES (?1, 'run', ?2, '1', ?3, 'stateless_required', NULL, NULL, 2, '{}')",
        bindings: [.text("\(prefix)-grant"), .text(profileID), .text(value)]
    )
    try database.execute(
        "INSERT INTO egress_generation_authorizations VALUES (?1, 'turn', ?2, ?3, 2, '{}')",
        bindings: [
            .text("\(prefix)-authorization"), .text("\(prefix)-grant"), .text(value),
        ]
    )
}

func expectLifecycleFailure<T>(
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

func temporaryLifecycleDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "credential-lifecycle-\(UUID().uuidString)",
        isDirectory: true
    )
}
