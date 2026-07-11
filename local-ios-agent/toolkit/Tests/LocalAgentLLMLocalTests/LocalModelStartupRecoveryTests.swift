import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("Ordered local model startup recovery")
struct LocalModelStartupRecoveryTests {
    @Test
    func oldEpochSessionsAndLeasesEndAtomicallyBeforeCurrentEpochUse() throws {
        let fixture = try installedStartupFixture()
        let oldEpoch = try HostProcessEpoch.generate()
        let newEpoch = try HostProcessEpoch.generate()
        let lease = LocalModelUseLease(
            leaseID: "old-lease",
            installationID: fixture.installationID,
            purpose: .activeSession,
            hostProcessEpoch: oldEpoch,
            state: .active,
            leaseRevision: 1
        )
        try fixture.store.acquireModelUseLease(lease)
        try fixture.store.seedPreparedLocalSessionForTesting(
            preparationID: "old-preparation",
            installationID: fixture.installationID,
            hostProcessEpoch: oldEpoch
        )

        try fixture.store.recoverLocalSessionsAndUseLeasesForNewEpoch(newEpoch)

        #expect(try fixture.store.modelUseLease(leaseID: lease.leaseID)?.state == .endedEpoch)
        #expect(try fixture.store.preparedLocalSessionStateForTesting(
            preparationID: "old-preparation"
        ) == "closed")
        let currentLease = LocalModelUseLease(
            leaseID: "current-lease",
            installationID: fixture.installationID,
            purpose: .loaded,
            hostProcessEpoch: newEpoch,
            state: .active,
            leaseRevision: 1
        )
        try fixture.store.acquireModelUseLease(currentLease)
    }

    @Test
    func fullRecoveryUsesTheRequiredOrderAndReturnsTheExactEpoch() async throws {
        let fixture = try installedStartupFixture()
        let epoch = try HostProcessEpoch.generate()
        let resources = try OfficialModelCatalogResources.loadBundled()
        let transport = StartupDownloadTransport()
        let downloads = ModelDownloadCoordinator(
            store: fixture.store,
            paths: fixture.paths,
            transport: transport
        )
        let stages = StartupStageRecorder()
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [fixture.manifest.id: fixture.manifest],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        let result = try await LocalModelStartupRecovery.run(
            store: fixture.store,
            hostProcessEpoch: epoch,
            bundledCatalog: resources.envelope,
            remoteCatalog: nil,
            reconciler: reconciler,
            downloads: downloads,
            stageObserver: stages.record
        )

        #expect(result.hostProcessEpoch == epoch)
        #expect(result.acceptedCatalog.verified.catalogRevision > 0)
        #expect(stages.values == [
            .epochReceived,
            .storeReady,
            .oldEpochEnded,
            .catalogAccepted,
            .filesystemReconciled,
            .downloadsRestored,
        ])
        #expect(transport.restoreCallCount == 1)
    }

    @Test(arguments: LocalStartupRecoveryCrashPoint.allCases)
    func noRecoveryTokenEscapesAnyInjectedStageFailure(
        _ crashPoint: LocalStartupRecoveryCrashPoint
    ) async throws {
        let fixture = try installedStartupFixture()
        let resources = try OfficialModelCatalogResources.loadBundled()
        let transport = StartupDownloadTransport()
        let downloads = ModelDownloadCoordinator(
            store: fixture.store,
            paths: fixture.paths,
            transport: transport
        )
        let reconciler = LocalModelReconciler(
            store: fixture.store,
            paths: fixture.paths,
            manifestsByRevision: [fixture.manifest.id: fixture.manifest],
            validator: fixture.validator,
            backupExclusion: fixture.backup
        )

        do {
            _ = try await LocalModelStartupRecovery.run(
                store: fixture.store,
                hostProcessEpoch: try HostProcessEpoch.generate(),
                bundledCatalog: resources.envelope,
                remoteCatalog: nil,
                reconciler: reconciler,
                downloads: downloads,
                crashPointForTesting: crashPoint
            )
            Issue.record("recovery token escaped injected failure")
        } catch let failure as LLMFailure {
            #expect(failure.code == "runtime.local_startup_recovery_incomplete")
        }
    }
}

private func installedStartupFixture() throws -> TestLocalInstallFixture {
    let fixture = try TestLocalInstallFixture(installationID: "startup-installed")
    try fixture.prepareVerifyingInstallation()
    try LocalModelInstaller(
        store: fixture.store,
        paths: fixture.paths,
        validator: fixture.validator,
        backupExclusion: fixture.backup
    ).verifyAndInstall(installationID: fixture.installationID, manifest: fixture.manifest)
    return fixture
}

private final class StartupDownloadTransport: ModelDownloadTransport, @unchecked Sendable {
    let events: AsyncStream<ModelDownloadTransportEvent>
    private let lock = NSLock()
    private(set) var restoreCallCount = 0

    init() {
        events = AsyncStream(bufferingPolicy: .unbounded) { _ in }
    }

    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int { 1 }

    func restoredTasks() async throws -> [RestoredModelDownload] {
        lock.withLock { restoreCallCount += 1 }
        return []
    }

    func pause(taskIdentifier: Int) async throws -> Data? { nil }
    func cancel(taskIdentifier: Int) async {}
    func setBackgroundEventsCompletionHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async {}
}

private final class StartupStageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [LocalStartupRecoveryStage] = []
    func record(_ stage: LocalStartupRecoveryStage) {
        lock.withLock { values.append(stage) }
    }
}
