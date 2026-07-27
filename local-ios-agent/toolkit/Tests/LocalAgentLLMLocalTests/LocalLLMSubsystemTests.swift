import Foundation
import LocalAgentLLMContracts
import LocalAgentLLMCore
import Testing
@testable import LocalAgentLLMLocal

@Suite("Local LLM subsystem bootstrap")
struct LocalLLMSubsystemTests {
    @Test
    func bootstrapUsesTheAppEpochAndDoesNotExposeBeforeRecoveryCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = try HostProcessEpoch.generate()
        let transport = BootstrapTransport()
        let resources = try OfficialModelCatalogResources.loadBundled()
        let llmStore = try LLMStore(
            fileURL: root.appending(path: "LocalAgent/LLM/llm-state.sqlite")
        )

        let subsystem = try await LocalLLMSubsystem.bootstrap(
            appSupportRoot: root,
            hostProcessEpoch: epoch,
            bundledCatalog: resources.envelope,
            remoteCatalog: nil,
            transport: transport,
            inference: BootstrapInference(),
            llmStore: llmStore
        )

        #expect(subsystem.hostProcessEpoch == epoch)
        #expect(transport.restoredCallCount == 1)
        #expect(subsystem.acceptedCatalog.verified.catalogRevision > 0)
        #expect(subsystem.store.fileURL == root.appending(path: "LocalAgent/LLM/local-models.sqlite"))
        #expect(subsystem.bindingStore === llmStore)
        #expect(await subsystem.runtime.state == .idle)

        let manifest = try #require(subsystem.acceptedCatalog.verified.models.first?.value)
        var changes = subsystem.downloadStateChanges.makeAsyncIterator()
        let installationID = try await subsystem.enqueue(
            modelRevision: manifest.id,
            installationID: "product-installation"
        )
        #expect(installationID == "product-installation")
        #expect(await changes.next() != nil)
        let inventory = try await subsystem.inventory()
        #expect(inventory.count == 1)
        #expect(inventory[0].installationID == installationID)
        #expect(inventory[0].modelRevision == manifest.id)
        #expect(inventory[0].expectedBytes == manifest.artifacts.reduce(0) {
            $0 + $1.byteSize
        })
        #expect(inventory[0].requiredBytes == manifest.installedByteSize)
        #expect(!String(describing: inventory[0]).contains(root.path))

        try await subsystem.pause(installationID: installationID)
        #expect(try await subsystem.inventory()[0].state == .paused)
        try await subsystem.resume(installationID: installationID)
        #expect(try await subsystem.inventory()[0].state == .downloading)
        try await subsystem.cancel(installationID: installationID)
        #expect(try await subsystem.inventory().isEmpty)
        _ = try await subsystem.diskState()
    }
}

private final class BootstrapTransport: ModelDownloadTransport, @unchecked Sendable {
    let events: AsyncStream<ModelDownloadTransportEvent>
    private let lock = NSLock()
    private var restoredCalls = 0

    init() {
        events = AsyncStream { _ in }
    }

    var restoredCallCount: Int { lock.withLock { restoredCalls } }
    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int { 1 }
    func restoredTasks() async throws -> [RestoredModelDownload] {
        lock.withLock { restoredCalls += 1 }
        return []
    }
    func pause(taskIdentifier: Int) async throws -> Data? { nil }
    func cancel(taskIdentifier: Int) async {}
    func setBackgroundEventsCompletionHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async {}
}

private struct BootstrapInference: CppInferenceAPI {
    func listEngines() throws -> [CppEngineDescriptor] { [] }
    func validateModel(_ request: CppModelLoadRequest) throws {}
    func load(_ request: CppModelLoadRequest) throws -> any CppLoadedModelAPI {
        throw LLMFailure(
            code: "local_engine.unexpected_load",
            message: "bootstrap must not load model weights",
            retryable: false
        )
    }
}
