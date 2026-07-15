import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMLocal

@Suite("Single-model local runtime")
struct LocalModelRuntimeTests {
    @Test
    func preparationLoadsOnFirstUseReusesRAMAndEnforcesOneSessionAndGeneration() async throws {
        let fixture = try await RuntimeFixture.make()

        let first = try await fixture.runtime.prepareSession(
            hostConfiguration: fixture.configuration,
            target: fixture.target
        )
        #expect(fixture.inference.loadCount == 1)
        #expect(first.targetID == fixture.target.targetID)
        #expect(first.installationStateRevision == fixture.installation.stateRevision)
        #expect(first.capabilitySnapshot.subject.llmTargetID == fixture.target.targetID)
        #expect(!first.capabilitySnapshotDigest.isEmpty)
        #expect(!first.resolvedParametersDigest.isEmpty)

        await #expect(throws: LLMFailure.self) {
            try await fixture.runtime.prepareSession(
                hostConfiguration: fixture.configuration,
                target: fixture.target
            )
        }

        let events = try await fixture.runtime.startGeneration(
            sessionID: first.sessionID,
            input: AgentLLMInput(
                inputID: "turn-1",
                messages: [LLMInputMessage(role: .user, content: [.text("hello")])]
            ),
            attachments: [],
            toolSchema: nil
        )
        await #expect(throws: LLMFailure.self) {
            try await fixture.runtime.startGeneration(
                sessionID: first.sessionID,
                input: AgentLLMInput(inputID: "turn-2", messages: []),
                attachments: [],
                toolSchema: nil
            )
        }
        var received: [LLMBackendEvent] = []
        for try await event in events { received.append(event) }
        #expect(received == [
            .textDelta("hello"),
            .generationCompleted(LLMBackendCompletion(
                outcome: .finalResponse,
                orderedCallIDs: [],
                finishReason: .stop
            )),
        ])

        try await fixture.runtime.closeSession(sessionID: first.sessionID)
        let second = try await fixture.runtime.prepareSession(
            hostConfiguration: fixture.configuration,
            target: fixture.target
        )
        #expect(second.sessionID != first.sessionID)
        #expect(fixture.inference.loadCount == 1)
        try await fixture.runtime.closeSession(sessionID: second.sessionID)
        try await fixture.runtime.unload()
        #expect(fixture.inference.unloadCount == 1)
        #expect(try fixture.store.modelUseLease(leaseID: first.loadedModelLeaseID)?.state == .released)
    }

    @Test
    func cancellationReleasesGenerationButRetainsSessionLeaseUntilExplicitClose() async throws {
        let fixture = try await RuntimeFixture.make(generationMode: .blocksUntilCancel)
        let session = try await fixture.runtime.prepareSession(
            hostConfiguration: fixture.configuration,
            target: fixture.target
        )
        _ = try await fixture.runtime.startGeneration(
            sessionID: session.sessionID,
            input: AgentLLMInput(
                inputID: "turn-cancel",
                messages: [LLMInputMessage(role: .user, content: [.text("wait")])]
            ),
            attachments: [],
            toolSchema: nil
        )

        try await fixture.runtime.cancel(sessionID: session.sessionID)
        #expect(fixture.inference.cancelCount == 1)
        #expect(fixture.inference.releaseCount == 1)
        #expect(try fixture.store.modelUseLease(leaseID: session.activeSessionLeaseID)?.state == .active)
        try await fixture.runtime.closeSession(sessionID: session.sessionID)
        #expect(try fixture.store.modelUseLease(leaseID: session.activeSessionLeaseID)?.state == .released)
    }
}

private struct RuntimeFixture {
    let store: LocalModelStore
    let inference: FakeInference
    let runtime: LocalModelRuntime
    let target: LLMTargetRevision
    let configuration: AgentHostConfiguration
    let installation: LocalInstallationSummary

    static func make(
        generationMode: FakeInference.GenerationMode = .immediate
    ) async throws -> RuntimeFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let paths = try LocalModelPaths(root: root)
        let store = try LocalModelStore.inMemory()
        let resources = try OfficialModelCatalogResources.loadBundled()
        let accepted = try OfficialModelCatalogService(store: store).accept(
            bundled: resources.envelope,
            remote: nil
        )
        let manifest = try #require(accepted.verified.models.values.first)
        var installation = try store.enqueueInstallation(
            installationID: "installation-1",
            modelRevision: manifest.id,
            rootPath: try paths.finalInstallation("installation-1").path
        )
        installation = try store.transitionInstallation(
            installationID: installation.installationID,
            expectedStateRevision: installation.stateRevision,
            to: .downloading
        )
        installation = try store.transitionInstallation(
            installationID: installation.installationID,
            expectedStateRevision: installation.stateRevision,
            to: .verifying
        )
        installation = try store.transitionInstallation(
            installationID: installation.installationID,
            expectedStateRevision: installation.stateRevision,
            to: .installed
        )

        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "target-local"),
            revision: 3,
            kind: .local(installationID: installation.installationID),
            modelID: manifest.id.modelID,
            defaultParameters: GenerationConfiguration()
        )
        let configuration = AgentHostConfiguration(
            bindingID: "binding-local",
            revision: 5,
            agentProfileID: "profile-1",
            agentProfileRevision: 2,
            llmSlotID: "assistant",
            requirementsHash: "requirements-hash",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let bindingStore = LLMStore.inMemory()
        let saga = AgentHostBindingSaga(store: bindingStore)
        let staged = try await saga.stageHostBinding(HostBindingStageRequest(
            operationToken: "binding-token",
            tokenDigest: "binding-token-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        ))
        try await saga.activateHostBinding(
            operationToken: "binding-token",
            binding: staged.binding
        )
        let inference = FakeInference(manifest: manifest, mode: generationMode)
        let runtime = LocalModelRuntime(
            store: store,
            paths: paths,
            catalog: accepted,
            bindingSaga: saga,
            inference: inference,
            hostProcessEpoch: try HostProcessEpoch.generate(),
            appBuild: "tests"
        )
        return RuntimeFixture(
            store: store,
            inference: inference,
            runtime: runtime,
            target: target,
            configuration: configuration,
            installation: installation
        )
    }
}

private final class FakeInference: CppInferenceAPI, @unchecked Sendable {
    enum GenerationMode { case immediate, blocksUntilCancel }

    private let lock = NSLock()
    private let descriptor: CppEngineDescriptor
    private let mode: GenerationMode
    private var loads = 0
    private var unloads = 0
    private var cancels = 0
    private var releases = 0

    init(manifest: LocalModelRevisionManifest, mode: GenerationMode) {
        self.mode = mode
        descriptor = CppEngineDescriptor(
            engineID: manifest.engineID,
            abiVersion: "2",
            engineVersion: "fake-engine-v2",
            displayName: "Fake engine",
            testOnly: false,
            capabilities: CppEngineCapabilities(
                supportedModelFormats: [manifest.modelFormat],
                supportsVision: false,
                supportsStreaming: true,
                supportsCancellation: true,
                supportsTokenUsage: false,
                maxContextTokens: manifest.loadTemplate.contextTokens,
                backendParameters: fakeParameters
            )
        )
    }

    var loadCount: Int { lock.withLock { loads } }
    var unloadCount: Int { lock.withLock { unloads } }
    var cancelCount: Int { lock.withLock { cancels } }
    var releaseCount: Int { lock.withLock { releases } }

    func listEngines() throws -> [CppEngineDescriptor] { [descriptor] }
    func validateModel(_ request: CppModelLoadRequest) throws {}
    func load(_ request: CppModelLoadRequest) throws -> any CppLoadedModelAPI {
        lock.withLock { loads += 1 }
        return FakeLoadedModel(owner: self, mode: mode)
    }

    fileprivate func didUnload() { lock.withLock { unloads += 1 } }
    fileprivate func didCancel() { lock.withLock { cancels += 1 } }
    fileprivate func didRelease() { lock.withLock { releases += 1 } }
}

private final class FakeLoadedModel: CppLoadedModelAPI, @unchecked Sendable {
    private let owner: FakeInference
    private let mode: FakeInference.GenerationMode

    init(owner: FakeInference, mode: FakeInference.GenerationMode) {
        self.owner = owner
        self.mode = mode
    }

    func validateGeneration(_ request: CppGenerationRequest) throws {}
    func start(_ request: CppGenerationRequest) throws -> any CppGenerationAPI {
        FakeGeneration(owner: owner, mode: mode)
    }
    func unload() throws { owner.didUnload() }
}

private final class FakeGeneration: CppGenerationAPI, @unchecked Sendable {
    private let owner: FakeInference
    private let channel = CppEventChannel(maxEventCount: 8, maxUTF8Bytes: 1024)

    init(owner: FakeInference, mode: FakeInference.GenerationMode) {
        self.owner = owner
        if mode == .immediate {
            _ = channel.send(.textDelta("hello"))
            _ = channel.send(.completed(rawFinishReason: "stop"))
            channel.finish()
        }
    }

    var events: CppTokenEventSequence { channel.sequence }
    func cancel() throws {
        owner.didCancel()
        channel.cancel()
    }
    func release() throws { owner.didRelease() }
}

private let fakeParameters = [
    CppParameterDescriptor(backendOption: "temperature", valueType: "number", minimum: 0, maximum: 2),
    CppParameterDescriptor(backendOption: "top_p", valueType: "number", minimum: 0, maximum: 1),
    CppParameterDescriptor(backendOption: "top_k", valueType: "integer", minimum: 0, maximum: 10_000),
    CppParameterDescriptor(backendOption: "min_p", valueType: "number", minimum: 0, maximum: 1),
    CppParameterDescriptor(backendOption: "repeat_penalty", valueType: "number", minimum: 0, maximum: 2),
    CppParameterDescriptor(backendOption: "max_new_tokens", valueType: "integer", minimum: 1, maximum: 32_768),
    CppParameterDescriptor(backendOption: "seed", valueType: "integer", minimum: nil, maximum: nil),
    CppParameterDescriptor(backendOption: "stop_sequences", valueType: "string_array", minimum: nil, maximum: nil),
]
