import CryptoKit
import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMLocal

@Suite("Phase 2 local product path integration")
struct LocalProductPathIntegrationTests {
    @Test
    func unifiedPhaseTwoRunnerIsPresentBeforeTheProductPathIsAccepted() {
        #expect(FileManager.default.fileExists(
            atPath: phaseTwoRepositoryRoot()
                .appending(path: "scripts/run-llm-phase-2-contracts.sh")
                .path
        ))
    }

    @Test
    func signedCatalogDownloadInstallReopenCancelUnloadAndDelete() async throws {
        let fixture = try TestLocalInstallFixture(installationID: "phase-two-product")
        let signed = try signedCatalog(containing: fixture.manifest)
        let accepted = try OfficialModelCatalogService(
            store: fixture.store,
            keyRing: signed.keyRing
        ).accept(bundled: signed.envelope, remote: nil)
        #expect(accepted.verified.models[fixture.manifest.id] == fixture.manifest)

        let transport = IntegrationDownloadTransport(bytesByArtifactID: fixture.artifactData)
        let downloads = ModelDownloadCoordinator(
            store: fixture.store,
            paths: fixture.paths,
            transport: transport
        )
        try await downloads.enqueue(
            installationID: fixture.installationID,
            manifest: fixture.manifest
        )
        try await eventuallyPhaseTwo { transport.starts.count == 1 }

        try await downloads.pause(installationID: fixture.installationID)
        #expect(try fixture.store.installationSummary(
            installationID: fixture.installationID
        )?.state == .paused)
        try await downloads.resume(installationID: fixture.installationID)
        try await eventuallyPhaseTwo { transport.starts.count == 2 }

        var completedStartCount = 1
        while try fixture.store.installationSummary(
            installationID: fixture.installationID
        )?.state != .verifying {
            let previousStartCount = completedStartCount
            try await eventuallyPhaseTwo { transport.starts.count > previousStartCount }
            let start = try #require(transport.starts.last)
            try transport.complete(start)
            completedStartCount = transport.starts.count
            try await Task.sleep(for: .milliseconds(10))
        }

        let inference = IntegrationInference(manifest: fixture.manifest)
        try LocalModelInstaller(
            store: fixture.store,
            paths: fixture.paths,
            validator: inference,
            backupExclusion: fixture.backup
        ).verifyAndInstall(
            installationID: fixture.installationID,
            manifest: fixture.manifest
        )

        let reopened = try LocalModelStore(
            fileURL: fixture.root.appending(path: "local-models.sqlite"),
            backupExclusion: fixture.backup
        )
        let reopenedCatalog = try OfficialModelCatalogService(
            store: reopened,
            keyRing: signed.keyRing
        ).accept(bundled: signed.envelope, remote: nil)
        _ = try LocalModelReconciler(
            store: reopened,
            paths: fixture.paths,
            manifestsByRevision: reopenedCatalog.verified.models,
            validator: inference,
            backupExclusion: fixture.backup
        ).reconcileAtLaunch()
        #expect(try reopened.installationSummary(
            installationID: fixture.installationID
        )?.state == .installed)

        let target = LLMTargetRevision(
            targetID: LLMTargetID(rawValue: "phase-two-target"),
            revision: 1,
            kind: .local(installationID: fixture.installationID),
            modelID: fixture.manifest.id.modelID,
            defaultParameters: GenerationConfiguration()
        )
        let configuration = AgentHostConfiguration(
            bindingID: "phase-two-binding",
            revision: 1,
            agentProfileID: "phase-two-profile",
            agentProfileRevision: 1,
            llmSlotID: "assistant",
            requirementsHash: "phase-two-requirements",
            llmTargetID: target.targetID,
            llmTargetRevision: target.revision,
            parameterOverrides: GenerationConfiguration()
        )
        let bindingStore = LLMStore.inMemory()
        let bindingSaga = AgentHostBindingSaga(store: bindingStore)
        let staged = try await bindingSaga.stageHostBinding(HostBindingStageRequest(
            operationToken: "phase-two-operation",
            tokenDigest: "phase-two-operation-digest",
            llmSlotID: configuration.llmSlotID,
            requirementsHash: configuration.requirementsHash,
            configuration: configuration
        ))
        try await bindingSaga.activateHostBinding(
            operationToken: "phase-two-operation",
            binding: staged.binding
        )
        let epoch = try HostProcessEpoch.generate()
        let runtime = LocalModelRuntime(
            store: reopened,
            paths: fixture.paths,
            catalog: reopenedCatalog,
            bindingSaga: bindingSaga,
            inference: inference,
            hostProcessEpoch: epoch,
            appBuild: "phase-two-integration"
        )
        let session = try await runtime.prepareSession(
            hostConfiguration: configuration,
            target: target
        )
        #expect(session.hostProcessEpoch == epoch)

        do {
            try LocalModelDeletionService(store: reopened, paths: fixture.paths)
                .delete(installationID: fixture.installationID)
            Issue.record("loaded installation must not be deletable")
        } catch let failure as LLMFailure {
            #expect(failure.code == "deletion.model_in_use")
        }

        _ = try await runtime.startGeneration(
            sessionID: session.sessionID,
            input: AgentLLMInput(
                inputID: "phase-two-turn",
                messages: [LLMInputMessage(role: .user, content: [.text("hello")])]
            ),
            attachments: [],
            toolSchema: nil
        )
        try await runtime.cancel(sessionID: session.sessionID)
        try await runtime.closeSession(sessionID: session.sessionID)
        try await runtime.unload()
        #expect(inference.cancelCount == 1)

        try LocalModelDeletionService(store: reopened, paths: fixture.paths)
            .delete(installationID: fixture.installationID)
        #expect(try reopened.installationSummary(installationID: fixture.installationID) == nil)
    }

    @Test
    func insufficientSpaceAndCorruptionFailBeforeRunnableInstallation() async throws {
        let diskFixture = try TestLocalInstallFixture(installationID: "phase-two-disk")
        _ = try diskFixture.store.enqueueInstallation(
            installationID: diskFixture.installationID,
            modelRevision: diskFixture.manifest.id,
            rootPath: try diskFixture.paths.finalInstallation(diskFixture.installationID).path
        )
        let policy = LocalDiskPolicy(store: diskFixture.store, root: diskFixture.root)
        do {
            _ = try await policy.preflight(
                installationID: diskFixture.installationID,
                manifest: diskFixture.manifest,
                completedArtifactBytes: 0,
                volume: IntegrationVolume(bytes: 0)
            )
            Issue.record("insufficient storage must fail")
        } catch let failure as LLMFailure {
            #expect(failure.code == "download.insufficient_disk")
        }
        #expect(try diskFixture.store.totalReservedBytes() == 0)

        let corrupt = try TestLocalInstallFixture(installationID: "phase-two-corrupt")
        try corrupt.prepareVerifyingInstallation(corruption: .oneBitHashMismatch)
        do {
            try LocalModelInstaller(
                store: corrupt.store,
                paths: corrupt.paths,
                validator: corrupt.validator,
                backupExclusion: corrupt.backup
            ).verifyAndInstall(
                installationID: corrupt.installationID,
                manifest: corrupt.manifest
            )
            Issue.record("corrupt artifact must fail")
        } catch let failure as LLMFailure {
            #expect(failure.code == "installation.checksum_mismatch")
        }
        #expect(try corrupt.store.installationSummary(
            installationID: corrupt.installationID
        )?.state == .failed)
    }
}

private struct SignedIntegrationCatalog {
    let envelope: Data
    let keyRing: Data
}

private func signedCatalog(
    containing manifest: LocalModelRevisionManifest
) throws -> SignedIntegrationCatalog {
    let payload = SignedLocalModelCatalogPayload(
        schemaVersion: "1",
        keyID: "test-phase-two-key",
        catalogRevision: 1,
        models: [manifest],
        revokedModelRevisions: []
    )
    let key = Curve25519.Signing.PrivateKey()
    let canonical = try LocalModelCatalogCanonicalDocument.canonicalSignedBytes(from: payload)
    let envelope = CatalogEnvelope(
        signed: payload,
        signature: Base64URL.encode(try key.signature(for: canonical))
    )
    let keyRing = try JSONSerialization.data(withJSONObject: [
        "schema_version": "1",
        "keys": [[
            "key_id": payload.keyID,
            "public_key": Base64URL.encode(key.publicKey.rawRepresentation),
            "status": "active",
        ]],
    ])
    return SignedIntegrationCatalog(
        envelope: try JSONEncoder().encode(envelope),
        keyRing: keyRing
    )
}

private struct IntegrationVolume: LocalVolumeCapacity {
    let bytes: UInt64
    func availableImportantUsageBytes(at root: URL) throws -> UInt64 { bytes }
}

private final class IntegrationDownloadTransport: ModelDownloadTransport, @unchecked Sendable {
    struct Start: Sendable {
        let taskIdentifier: Int
        let request: ArtifactDownloadRequest
    }

    let events: AsyncStream<ModelDownloadTransportEvent>
    private let continuation: AsyncStream<ModelDownloadTransportEvent>.Continuation
    private let lock = NSLock()
    private let bytesByArtifactID: [String: Data]
    private var recordedStarts: [Start] = []
    private var nextTaskIdentifier = 1

    init(bytesByArtifactID: [String: Data]) {
        self.bytesByArtifactID = bytesByArtifactID
        let pair = AsyncStream<ModelDownloadTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        events = pair.stream
        continuation = pair.continuation
    }

    var starts: [Start] { lock.withLock { recordedStarts } }

    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int {
        lock.withLock {
            let identifier = nextTaskIdentifier
            nextTaskIdentifier += 1
            recordedStarts.append(Start(taskIdentifier: identifier, request: request))
            return identifier
        }
    }

    func restoredTasks() async throws -> [RestoredModelDownload] { [] }
    func pause(taskIdentifier: Int) async throws -> Data? { Data("phase-two-resume".utf8) }
    func cancel(taskIdentifier: Int) async {}
    func setBackgroundEventsCompletionHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async {}

    func complete(_ start: Start) throws {
        let bytes = try #require(bytesByArtifactID[start.request.artifactID])
        try FileManager.default.createDirectory(
            at: start.request.stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: start.request.stagingURL)
        continuation.yield(.completed(
            taskIdentifier: start.taskIdentifier,
            stagedFileURL: start.request.stagingURL,
            etag: "phase-two-etag",
            lastModified: "Wed, 15 Jul 2026 00:00:00 GMT"
        ))
    }
}

private final class IntegrationInference:
    CppInferenceAPI,
    LocalModelConfigValidator,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let descriptor: CppEngineDescriptor
    private var cancellations = 0

    init(manifest: LocalModelRevisionManifest) {
        descriptor = CppEngineDescriptor(
            engineID: manifest.engineID,
            abiVersion: "2",
            engineVersion: "phase-two-fake-v1",
            displayName: "Phase 2 fake",
            testOnly: false,
            capabilities: CppEngineCapabilities(
                supportedModelFormats: [manifest.modelFormat],
                supportsVision: false,
                supportsStreaming: true,
                supportsCancellation: true,
                supportsTokenUsage: false,
                maxContextTokens: manifest.loadTemplate.contextTokens,
                backendParameters: []
            )
        )
    }

    var cancelCount: Int { lock.withLock { cancellations } }
    func listEngines() throws -> [CppEngineDescriptor] { [descriptor] }
    func validateModel(_ request: CppModelLoadRequest) throws {}
    func validate(
        manifest: LocalModelRevisionManifest,
        artifactPathsByRole: [LocalModelArtifactRole: URL]
    ) throws {}
    func load(_ request: CppModelLoadRequest) throws -> any CppLoadedModelAPI {
        IntegrationLoadedModel(owner: self)
    }
    fileprivate func cancelled() { lock.withLock { cancellations += 1 } }
}

private final class IntegrationLoadedModel: CppLoadedModelAPI, @unchecked Sendable {
    private let owner: IntegrationInference
    init(owner: IntegrationInference) { self.owner = owner }
    func validateGeneration(_ request: CppGenerationRequest) throws {}
    func start(_ request: CppGenerationRequest) throws -> any CppGenerationAPI {
        IntegrationGeneration(owner: owner)
    }
    func unload() throws {}
}

private final class IntegrationGeneration: CppGenerationAPI, @unchecked Sendable {
    private let owner: IntegrationInference
    private let channel = CppEventChannel(maxEventCount: 4, maxUTF8Bytes: 256)
    init(owner: IntegrationInference) { self.owner = owner }
    var events: CppTokenEventSequence { channel.sequence }
    func cancel() throws {
        owner.cancelled()
        channel.cancel()
    }
    func release() throws {}
}

private func eventuallyPhaseTwo(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LLMFailure(
        code: "phase_two.integration_timeout",
        message: "integration condition was not satisfied",
        retryable: false
    )
}

private func phaseTwoRepositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
