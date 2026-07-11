import Foundation
import LocalAgentLLMContracts
@testable import LocalAgentLLMCore
import Testing

private func configuration(bindingID: String = "binding-1", revision: UInt64 = 1) -> AgentHostConfiguration {
    AgentHostConfiguration(
        bindingID: bindingID,
        revision: revision,
        agentProfileID: "profile-1",
        agentProfileRevision: 4,
        llmSlotID: "assistant",
        requirementsHash: "requirements-hash-1",
        llmTargetID: LLMTargetID(rawValue: "target-1"),
        llmTargetRevision: 2,
        parameterOverrides: GenerationConfiguration()
    )
}

@Test
func stagedBindingIsIdempotentAndDoesNotBecomeActiveEarly() async throws {
    let store = LLMStore.inMemory()
    let saga = AgentHostBindingSaga(store: store)
    let request = HostBindingStageRequest(
        operationToken: "publish-token-1",
        tokenDigest: "token-digest-1",
        llmSlotID: "assistant",
        requirementsHash: "requirements-hash-1",
        configuration: configuration()
    )

    let first = try await saga.stageHostBinding(request)
    let replay = try await saga.stageHostBinding(request)
    #expect(first == replay)
    #expect(await store.bindingState(token: request.operationToken) == .staged)

    try await saga.activateHostBinding(
        operationToken: request.operationToken,
        binding: first.binding
    )
    #expect(await store.bindingState(token: request.operationToken) == .active)
}

@Test
func conflictingStageOrActivationFailsClosed() async throws {
    let store = LLMStore.inMemory()
    let saga = AgentHostBindingSaga(store: store)
    let request = HostBindingStageRequest(
        operationToken: "publish-token-2",
        tokenDigest: "token-digest-2",
        llmSlotID: "assistant",
        requirementsHash: "requirements-hash-1",
        configuration: configuration()
    )
    let receipt = try await saga.stageHostBinding(request)

    let conflict = HostBindingStageRequest(
        operationToken: request.operationToken,
        tokenDigest: request.tokenDigest,
        llmSlotID: request.llmSlotID,
        requirementsHash: request.requirementsHash,
        configuration: configuration(revision: 2)
    )
    await #expect(throws: HostBindingSagaError.self) {
        try await saga.stageHostBinding(conflict)
    }
    await #expect(throws: HostBindingSagaError.self) {
        try await saga.activateHostBinding(
            operationToken: request.operationToken,
            binding: HostBindingTuple(
                bindingID: receipt.binding.bindingID,
                bindingRevision: receipt.binding.bindingRevision + 1,
                bindingHash: receipt.binding.bindingHash
            )
        )
    }
}

@Test
func reconciliationConvergesAfterStoreReopen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("llm-store.json")
    let request = HostBindingStageRequest(
        operationToken: "package-token-1",
        tokenDigest: "token-digest-3",
        llmSlotID: "assistant",
        requirementsHash: "requirements-hash-1",
        configuration: configuration(bindingID: "binding-3")
    )

    let firstStore = try LLMStore(fileURL: url)
    let receipt = try await AgentHostBindingSaga(store: firstStore).stageHostBinding(request)
    #expect(await firstStore.bindingState(token: request.operationToken) == .staged)

    let reopened = try LLMStore(fileURL: url)
    let saga = AgentHostBindingSaga(store: reopened)
    let outcome = try await saga.reconcileHostBindings([
        RustHostBindingCrossLink(
            operationToken: request.tokenDigest,
            tokenDigest: request.tokenDigest,
            llmSlotID: request.llmSlotID,
            requirementsHash: request.requirementsHash,
            binding: receipt.binding
        )
    ])

    #expect(outcome.activatedTokens == [request.tokenDigest])
    #expect(outcome.repairTokens.isEmpty)
    #expect(await reopened.bindingState(token: request.tokenDigest) == .active)
}

@Test
func reconciliationExposesRepairForTupleMismatch() async throws {
    let store = LLMStore.inMemory()
    let saga = AgentHostBindingSaga(store: store)
    let request = HostBindingStageRequest(
        operationToken: "publish-token-4",
        tokenDigest: "token-digest-4",
        llmSlotID: "assistant",
        requirementsHash: "requirements-hash-1",
        configuration: configuration(bindingID: "binding-4")
    )
    let receipt = try await saga.stageHostBinding(request)
    let mismatch = HostBindingTuple(
        bindingID: receipt.binding.bindingID,
        bindingRevision: receipt.binding.bindingRevision,
        bindingHash: "different-hash"
    )

    let outcome = try await saga.reconcileHostBindings([
        RustHostBindingCrossLink(
            operationToken: request.operationToken,
            tokenDigest: request.tokenDigest,
            llmSlotID: request.llmSlotID,
            requirementsHash: request.requirementsHash,
            binding: mismatch
        )
    ])
    #expect(outcome.activatedTokens.isEmpty)
    #expect(outcome.repairTokens == [request.operationToken])
    #expect(await store.bindingState(token: request.operationToken) == .staged)
}

@Test
func persistenceFailuresRollBackStageAndActivation() async throws {
    let store = LLMStore.inMemory()
    let saga = AgentHostBindingSaga(store: store)
    let request = HostBindingStageRequest(
        operationToken: "publish-token-failure",
        tokenDigest: "token-digest-failure",
        llmSlotID: "assistant",
        requirementsHash: "requirements-hash-1",
        configuration: configuration(bindingID: "binding-failure")
    )

    await store.failNextPersistenceForTesting()
    await #expect(throws: HostBindingSagaError.self) {
        try await saga.stageHostBinding(request)
    }
    #expect(await store.bindingState(token: request.operationToken) == nil)

    let receipt = try await saga.stageHostBinding(request)
    await store.failNextPersistenceForTesting()
    await #expect(throws: HostBindingSagaError.self) {
        try await saga.activateHostBinding(
            operationToken: request.operationToken,
            binding: receipt.binding
        )
    }
    #expect(await store.bindingState(token: request.operationToken) == .staged)
}
