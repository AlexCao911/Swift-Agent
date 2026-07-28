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
            llmStore: llmStore,
            deviceCapabilities: capablePhone,
            volume: BootstrapVolume(bytes: UInt64.max)
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

    @Test
    func enqueueRejectsInsufficientDiskBeforeStartingTransport() async throws {
        let fixture = try await makeSubsystem(volumeBytes: 0)
        let manifest = try #require(
            fixture.subsystem.compatibleModels().first
        )

        await #expect(throws: LLMFailure.self) {
            _ = try await fixture.subsystem.enqueue(
                modelRevision: manifest.id,
                installationID: "no-space"
            )
        }

        #expect(fixture.transport.startCount == 0)
        #expect(try await fixture.subsystem.inventory().isEmpty)
        #expect(try fixture.subsystem.store.totalReservedBytes() == 0)
    }

    @Test
    func inventoryKeepsSupersededInstallationsManageable() async throws {
        let fixture = try await makeSubsystem(volumeBytes: UInt64.max)
        let revision = LocalModelRevisionID(modelID: "retired-model", revision: 9)
        var summary = try fixture.subsystem.store.enqueueInstallation(
            installationID: "retired-installation",
            modelRevision: revision,
            rootPath: "/retired"
        )
        summary = try fixture.subsystem.store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .downloading
        )
        summary = try fixture.subsystem.store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .verifying
        )
        _ = try fixture.subsystem.store.transitionInstallation(
            installationID: summary.installationID,
            expectedStateRevision: summary.stateRevision,
            to: .installed
        )

        let inventory = try await fixture.subsystem.inventory()
        let retired = try #require(inventory.first {
            $0.installationID == "retired-installation"
        })
        #expect(retired.catalogStatus == .superseded)
        #expect(retired.repairAction == .delete)
    }

    @Test
    func incompatibleExistingInstallationsRemainManageableButNotSelectable() async throws {
        let fixture = try await makeSubsystem(
            volumeBytes: UInt64.max,
            deviceCapabilities: LocalDeviceCapabilities(
                osMajor: 99,
                deviceClass: .phone,
                physicalMemoryBytes: 1_024 * 1_024 * 1_024
            )
        )
        let manifest = try #require(
            fixture.subsystem.acceptedCatalog.verified.models.first?.value
        )
        _ = try fixture.subsystem.store.enqueueInstallation(
            installationID: "incompatible-installation",
            modelRevision: manifest.id,
            rootPath: "/incompatible"
        )

        #expect(fixture.subsystem.compatibleModels().isEmpty)
        #expect(try await fixture.subsystem.inventory().first?.catalogStatus == .incompatible)
    }
}

private final class BootstrapTransport: ModelDownloadTransport, @unchecked Sendable {
    let events: AsyncStream<ModelDownloadTransportEvent>
    private let lock = NSLock()
    private var restoredCalls = 0
    private var starts = 0

    init() {
        events = AsyncStream { _ in }
    }

    var restoredCallCount: Int { lock.withLock { restoredCalls } }
    var startCount: Int { lock.withLock { starts } }
    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int {
        lock.withLock { starts += 1 }
        return 1
    }
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

private let capablePhone = LocalDeviceCapabilities(
    osMajor: 99,
    deviceClass: .phone,
    physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024
)

private struct BootstrapVolume: LocalVolumeCapacity {
    let bytes: UInt64
    func availableImportantUsageBytes(at root: URL) throws -> UInt64 { bytes }
}

private func makeSubsystem(
    volumeBytes: UInt64,
    deviceCapabilities: LocalDeviceCapabilities = capablePhone
) async throws -> (subsystem: LocalLLMSubsystem, transport: BootstrapTransport) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let transport = BootstrapTransport()
    let resources = try OfficialModelCatalogResources.loadBundled()
    let subsystem = try await LocalLLMSubsystem.bootstrap(
        appSupportRoot: root,
        hostProcessEpoch: try HostProcessEpoch.generate(),
        bundledCatalog: resources.envelope,
        remoteCatalog: nil,
        transport: transport,
        inference: BootstrapInference(),
        deviceCapabilities: deviceCapabilities,
        volume: BootstrapVolume(bytes: volumeBytes)
    )
    return (subsystem, transport)
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
