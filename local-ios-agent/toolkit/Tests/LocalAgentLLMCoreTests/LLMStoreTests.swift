import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMCore

@Suite("LLMStore SQLite")
struct LLMStoreTests {
    @Test
    func targetRevisionIsImmutableAndReopensWithActiveBinding() async throws {
        let (directory, url) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LLMStore(fileURL: url)
        let target = fixtureTarget()
        try await first.publishTarget(target)
        let configuration = fixtureConfiguration()
        let saga = AgentHostBindingSaga(store: first)
        let request = HostBindingStageRequest(
            operationToken: "publish-target-1",
            tokenDigest: "publish-target-digest-1",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        )
        let receipt = try await saga.stageHostBinding(request)
        try await saga.activateHostBinding(
            operationToken: request.operationToken,
            binding: receipt.binding
        )

        let reopened = try LLMStore(fileURL: url)

        #expect(await reopened.target(reference: target.reference) == target)
        #expect(try await reopened.activeHostBindings() == [
            ActiveAgentHostBinding(
                configuration: configuration,
                binding: receipt.binding
            ),
        ])
    }

    @Test
    func duplicateTargetRevisionWithDifferentPayloadFailsClosed() async throws {
        let store = LLMStore.inMemory()
        let target = fixtureTarget()
        try await store.publishTarget(target)
        let conflict = LLMTargetRevision(
            targetID: target.targetID,
            revision: target.revision,
            kind: target.kind,
            modelID: "different-model",
            defaultParameters: target.defaultParameters
        )

        await #expect(throws: LLMStoreError.self) {
            try await store.publishTarget(conflict)
        }
        #expect(await store.targets() == [target])
    }

    @Test
    func activeBindingWithMissingTargetFailsClosed() async throws {
        let store = LLMStore.inMemory()
        let configuration = fixtureConfiguration()
        let saga = AgentHostBindingSaga(store: store)
        let request = HostBindingStageRequest(
            operationToken: "missing-target",
            tokenDigest: "missing-target-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        )
        let receipt = try await saga.stageHostBinding(request)
        try await saga.activateHostBinding(
            operationToken: request.operationToken,
            binding: receipt.binding
        )

        await #expect(throws: LLMStoreError.self) {
            try await store.activeHostBindings()
        }
    }

    @Test
    func targetPersistenceFailureRollsBackMemoryAndSQLite() async throws {
        let (directory, url) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LLMStore(fileURL: url)
        await store.failNextPersistenceForTesting()

        await #expect(throws: (any Error).self) {
            try await store.publishTarget(fixtureTarget())
        }

        #expect(await store.targets().isEmpty)
        #expect(await (try LLMStore(fileURL: url)).targets().isEmpty)
    }

    @Test
    func fileStoreCreatesVersionedNormalizedSQLiteDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("llm-state.sqlite")

        let store = try LLMStore(fileURL: url)
        let header = try Data(contentsOf: url).prefix(16)
        #expect(String(decoding: header, as: UTF8.self) == "SQLite format 3\0")
        #expect(await store.schemaVersionForTesting() == 2)
        let tables = Set(await store.tableNamesForTesting())
        #expect(tables.isSuperset(of: [
            "llm_store_meta",
            "host_bindings",
            "prepared_sessions",
            "llm_target_revisions",
        ]))
    }

    @Test
    func reopeningVersionTwoNeverDowngradesSharedSchema() async throws {
        let (directory, url) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteConnection(path: url.path)
        try LLMStoreSchema.ensureBaseSchema(database)
        try LLMStoreSchema.migrateToVersionTwo(database)

        let reopened = try LLMStore(fileURL: url)

        #expect(await reopened.schemaVersionForTesting() == 2)
    }

    @Test
    func bearerTokensNeverEnterSQLiteTextValues() async throws {
        let (directory, url) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LLMStore(fileURL: url)
        let hostBearer = "raw-host-bearer-must-not-persist"
        let preparationBearer = "raw-preparation-bearer-must-not-persist"
        let configuration = fixtureConfiguration()
        _ = try await AgentHostBindingSaga(store: store).stageHostBinding(
            HostBindingStageRequest(
                operationToken: hostBearer,
                tokenDigest: "host-token-digest",
                llmSlotID: configuration.llmSlotID,
                requirementsHash: configuration.requirementsHash,
                configuration: configuration
            )
        )
        _ = try await RunPreparationCoordinator(store: store).prepare(
            SwiftRunPreparationRequest(
                preview: SwiftRunPreparationPreview(
                    preparationID: "preparation-1",
                    proposedRunID: "run-1",
                    token: preparationBearer,
                    bindingDigest: "binding-digest-1",
                    hostProcessEpoch: "epoch-1",
                    expirationMillis: 300_000
                ),
                configuration: configuration
            )
        )

        let values = await store.allTextValuesForTesting()
        #expect(values.allSatisfy { !$0.contains(hostBearer) })
        #expect(values.allSatisfy { !$0.contains(preparationBearer) })
    }

    @Test
    func legacyJSONImportsOnceAndCorruptInputIsNotMutated() async throws {
        let (directory, url) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LLMStore.inMemory()
        let configuration = fixtureConfiguration()
        let request = HostBindingStageRequest(
            operationToken: "legacy-raw-token",
            tokenDigest: "legacy-token-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        )
        _ = try await AgentHostBindingSaga(store: source).stageHostBinding(request)
        let record = try #require(await source.record(token: request.operationToken))
        let legacy = LegacyDocument(
            schemaVersion: 1,
            hostBindings: [request.operationToken: record],
            preparedSessions: [:]
        )
        try JSONEncoder().encode(legacy).write(to: url)

        let imported = try LLMStore(fileURL: url)
        #expect(await imported.bindingState(token: request.tokenDigest) == .staged)
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("migrated").path
        ))
        #expect(String(decoding: try Data(contentsOf: url).prefix(16), as: UTF8.self)
            == "SQLite format 3\0")

        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: corruptURL)
        #expect(throws: (any Error).self) {
            _ = try LLMStore(fileURL: corruptURL)
        }
        #expect(try Data(contentsOf: corruptURL) == corrupt)
        #expect(!FileManager.default.fileExists(
            atPath: corruptURL.appendingPathExtension("migrated").path
        ))
    }

    @Test
    func concurrentStoreSnapshotsUseSQLCompareAndSwap() async throws {
        let (directory, url) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = fixtureConfiguration()
        let request = HostBindingStageRequest(
            operationToken: "ephemeral-bearer",
            tokenDigest: "cas-token-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        )
        let first = try LLMStore(fileURL: url)
        let receipt = try await AgentHostBindingSaga(store: first).stageHostBinding(request)
        let stale = try LLMStore(fileURL: url)
        try await AgentHostBindingSaga(store: first).activateHostBinding(
            operationToken: request.operationToken,
            binding: receipt.binding
        )

        await #expect(throws: HostBindingSagaError.self) {
            try await AgentHostBindingSaga(store: stale).activateHostBinding(
                operationToken: request.tokenDigest,
                binding: receipt.binding
            )
        }
    }
}

private struct LegacyDocument: Codable {
    let schemaVersion: UInt64
    let hostBindings: [String: StoredHostBindingRecord]
    let preparedSessions: [String: StoredPreparedSessionRecord]
}

private func temporaryDatabase() throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("llm-state.sqlite"))
}

private func fixtureConfiguration() -> AgentHostConfiguration {
    AgentHostConfiguration(
        bindingID: "binding-1",
        revision: 1,
        agentProfileID: "profile-1",
        agentProfileRevision: 1,
        llmSlotID: "assistant",
        requirementsHash: "requirements-1",
        llmTargetID: LLMTargetID(rawValue: "target-1"),
        llmTargetRevision: 1,
        parameterOverrides: GenerationConfiguration()
    )
}

private func fixtureTarget() -> LLMTargetRevision {
    LLMTargetRevision(
        targetID: LLMTargetID(rawValue: "target-1"),
        revision: 1,
        kind: .local(installationID: "installation-1"),
        modelID: "model-1",
        defaultParameters: GenerationConfiguration()
    )
}
