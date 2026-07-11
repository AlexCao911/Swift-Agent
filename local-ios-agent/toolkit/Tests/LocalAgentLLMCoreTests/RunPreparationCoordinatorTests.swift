import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing

private func swiftPreview(id: String = "preparation-1") -> SwiftRunPreparationPreview {
    SwiftRunPreparationPreview(
        preparationID: id,
        proposedRunID: "run-\(id)",
        token: "token-\(id)",
        bindingDigest: "binding-digest-\(id)",
        hostProcessEpoch: "epoch-1",
        expirationMillis: 300_000
    )
}

private func swiftConfiguration(bindingID: String = "binding-1") -> AgentHostConfiguration {
    AgentHostConfiguration(
        bindingID: bindingID,
        revision: 1,
        agentProfileID: "profile-1",
        agentProfileRevision: 4,
        llmSlotID: "assistant",
        requirementsHash: "requirements-1",
        llmTargetID: LLMTargetID(rawValue: "fake-target-1"),
        llmTargetRevision: 1,
        parameterOverrides: GenerationConfiguration()
    )
}

@Test
func phaseOnePreparationAllocatesIdentityWithoutOpeningBackend() async throws {
    let store = LLMStore.inMemory()
    let coordinator = RunPreparationCoordinator(store: store)
    let request = SwiftRunPreparationRequest(
        preview: swiftPreview(),
        configuration: swiftConfiguration()
    )

    let prepared = try await coordinator.prepare(request)
    #expect(prepared.resourceState == .allocatedNotOpened)
    #expect(try await coordinator.prepare(request) == prepared)
    #expect(await store.preparedSessionState(preparationID: request.preview.preparationID) == .prepared)
}

@Test
func conflictingPreparedIdentityFailsClosed() async throws {
    let store = LLMStore.inMemory()
    let coordinator = RunPreparationCoordinator(store: store)
    let preview = swiftPreview()
    _ = try await coordinator.prepare(.init(preview: preview, configuration: swiftConfiguration()))

    await #expect(throws: RunPreparationCoordinatorError.self) {
        try await coordinator.prepare(.init(
            preview: preview,
            configuration: swiftConfiguration(bindingID: "different-binding")
        ))
    }
}

@Test
func cleanupRequiresExactRegisteredSessionAndIsIdempotent() async throws {
    let store = LLMStore.inMemory()
    let coordinator = RunPreparationCoordinator(store: store)
    let prepared = try await coordinator.prepare(.init(
        preview: swiftPreview(),
        configuration: swiftConfiguration()
    ))
    let cleanup = SwiftPreparedSessionCleanupEnvelope(
        cleanupCommandID: "cleanup-1",
        preparationID: prepared.preparationID,
        proposedRunID: prepared.proposedRunID,
        sessionHandle: prepared.sessionHandle,
        hostProcessEpoch: prepared.hostProcessEpoch,
        cleanupSequence: 1,
        registrationDigest: prepared.registrationDigest,
        cleanupCommandDigest: "cleanup-digest-1"
    )

    await #expect(throws: RunPreparationCoordinatorError.self) {
        try await coordinator.closePreparedSession(cleanup)
    }
    let acknowledgement = try await coordinator.acknowledgePreparedSessionCleanup(cleanup)
    #expect(acknowledgement == .from(cleanup))
    #expect(try await coordinator.acknowledgePreparedSessionCleanup(cleanup) == acknowledgement)
    let receipt = try await coordinator.closePreparedSession(cleanup)
    #expect(receipt.closeDisposition == .closed)
    let replay = try await coordinator.closePreparedSession(cleanup)
    #expect(replay == receipt)
    #expect(await store.preparedSessionState(preparationID: prepared.preparationID) == .closed)
}

@Test
func wrongCleanupIdentityDoesNotClosePreparedSession() async throws {
    let store = LLMStore.inMemory()
    let coordinator = RunPreparationCoordinator(store: store)
    let prepared = try await coordinator.prepare(.init(
        preview: swiftPreview(),
        configuration: swiftConfiguration()
    ))
    let wrong = SwiftPreparedSessionCleanupEnvelope(
        cleanupCommandID: "cleanup-wrong",
        preparationID: prepared.preparationID,
        proposedRunID: prepared.proposedRunID,
        sessionHandle: "different-handle",
        hostProcessEpoch: prepared.hostProcessEpoch,
        cleanupSequence: 1,
        registrationDigest: prepared.registrationDigest,
        cleanupCommandDigest: "cleanup-digest-wrong"
    )

    await #expect(throws: RunPreparationCoordinatorError.self) {
        try await coordinator.acknowledgePreparedSessionCleanup(wrong)
    }
    #expect(await store.preparedSessionState(preparationID: prepared.preparationID) == .prepared)
}

@Test
func preparedSessionAndCloseReceiptSurviveReopen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("llm-store.json")
    let first = try LLMStore(fileURL: url)
    let coordinator = RunPreparationCoordinator(store: first)
    let prepared = try await coordinator.prepare(.init(
        preview: swiftPreview(id: "preparation-reopen"),
        configuration: swiftConfiguration()
    ))
    let cleanup = SwiftPreparedSessionCleanupEnvelope(
        cleanupCommandID: "cleanup-reopen",
        preparationID: prepared.preparationID,
        proposedRunID: prepared.proposedRunID,
        sessionHandle: prepared.sessionHandle,
        hostProcessEpoch: prepared.hostProcessEpoch,
        cleanupSequence: 1,
        registrationDigest: prepared.registrationDigest,
        cleanupCommandDigest: "cleanup-digest-reopen"
    )
    _ = try await coordinator.acknowledgePreparedSessionCleanup(cleanup)
    let receipt = try await coordinator.closePreparedSession(cleanup)

    let reopened = try LLMStore(fileURL: url)
    #expect(await reopened.preparedSessionState(preparationID: prepared.preparationID) == .closed)
    #expect(try await RunPreparationCoordinator(store: reopened).closePreparedSession(cleanup) == receipt)
}

@Test
func closeReceiptDigestBindsRegistrationCommandAndDisposition() throws {
    let base = SwiftPreparedSessionCleanupEnvelope(
        cleanupCommandID: "cleanup-digest",
        preparationID: "preparation-digest",
        proposedRunID: "run-digest",
        sessionHandle: "session-digest",
        hostProcessEpoch: "epoch-digest",
        cleanupSequence: 7,
        registrationDigest: "registration-a",
        cleanupCommandDigest: "command-a"
    )
    let registrationChanged = SwiftPreparedSessionCleanupEnvelope(
        cleanupCommandID: base.cleanupCommandID,
        preparationID: base.preparationID,
        proposedRunID: base.proposedRunID,
        sessionHandle: base.sessionHandle,
        hostProcessEpoch: base.hostProcessEpoch,
        cleanupSequence: base.cleanupSequence,
        registrationDigest: "registration-b",
        cleanupCommandDigest: base.cleanupCommandDigest
    )
    let commandChanged = SwiftPreparedSessionCleanupEnvelope(
        cleanupCommandID: base.cleanupCommandID,
        preparationID: base.preparationID,
        proposedRunID: base.proposedRunID,
        sessionHandle: base.sessionHandle,
        hostProcessEpoch: base.hostProcessEpoch,
        cleanupSequence: base.cleanupSequence,
        registrationDigest: base.registrationDigest,
        cleanupCommandDigest: "command-b"
    )

    let digest = try digestPreparedClose(base, disposition: .closed)
    #expect(digest != (try digestPreparedClose(registrationChanged, disposition: .closed)))
    #expect(digest != (try digestPreparedClose(commandChanged, disposition: .closed)))
    #expect(digest != (try digestPreparedClose(base, disposition: .alreadyClosed)))
}
