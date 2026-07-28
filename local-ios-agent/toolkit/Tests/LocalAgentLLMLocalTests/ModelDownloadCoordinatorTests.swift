import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentLLMLocal

@Suite("One-active local model downloads")
struct ModelDownloadCoordinatorTests {
    @Test
    func fifoQueueRunsOnlyOneArtifactAndDuplicateEnqueueIsIdempotent() async throws {
        let fixture = try DownloadFixture()
        let first = try productionManifest()
        let second = copy(first, id: LocalModelRevisionID(modelID: "second-model", revision: 1))

        try await fixture.coordinator.enqueue(installationID: "first", manifest: first)
        try await fixture.coordinator.enqueue(installationID: "first", manifest: first)
        try await fixture.coordinator.enqueue(installationID: "second", manifest: second)

        try await eventually { fixture.transport.snapshot().starts.count == 1 }
        #expect(fixture.transport.snapshot().maximumActiveCount == 1)
        let firstStart = try #require(fixture.transport.snapshot().starts.first)
        #expect(firstStart.request.installationID == "first")
        fixture.transport.complete(taskIdentifier: firstStart.taskIdentifier)

        try await eventually { fixture.transport.snapshot().starts.count == 2 }
        let secondStart = fixture.transport.snapshot().starts[1]
        #expect(secondStart.request.installationID == "second")
        #expect(fixture.transport.snapshot().maximumActiveCount == 1)
    }

    @Test
    func pausePersistsOpaqueResumeDataAndResumeKeepsArtifactIdentity() async throws {
        let fixture = try DownloadFixture()
        let manifest = try productionManifest()
        let resumeData = Data([0, 255, 17, 0, 42])
        fixture.transport.pauseData = resumeData
        try await fixture.coordinator.enqueue(installationID: "pause", manifest: manifest)
        try await eventually { fixture.transport.snapshot().starts.count == 1 }

        try await fixture.coordinator.pause(installationID: "pause")
        let artifactID = try #require(manifest.artifacts.first?.artifactID)
        #expect(try fixture.store.artifactRecord(
            installationID: "pause",
            artifactID: artifactID
        )?.resumeData == resumeData)

        try await fixture.coordinator.resume(installationID: "pause")
        try await eventually { fixture.transport.snapshot().starts.count == 2 }
        let starts = fixture.transport.snapshot().starts
        #expect(starts[1].request.installationID == starts[0].request.installationID)
        #expect(starts[1].request.artifactID == starts[0].request.artifactID)
        #expect(starts[1].resumeData == resumeData)
    }

    @Test
    func invalidResumeDataClearsOnlyThatArtifactAndRestartsAtZero() async throws {
        let fixture = try DownloadFixture()
        let manifest = try productionManifest()
        fixture.transport.pauseData = Data([7, 8, 9])
        try await fixture.coordinator.enqueue(installationID: "bad-resume", manifest: manifest)
        try await eventually { fixture.transport.snapshot().starts.count == 1 }
        try await fixture.coordinator.pause(installationID: "bad-resume")
        fixture.transport.rejectNextResumeData = true

        try await fixture.coordinator.resume(installationID: "bad-resume")

        try await eventually { fixture.transport.snapshot().starts.count == 3 }
        let starts = fixture.transport.snapshot().starts
        #expect(starts[1].resumeData == Data([7, 8, 9]))
        #expect(starts[2].resumeData == nil)
        let artifactID = try #require(manifest.artifacts.first?.artifactID)
        let storedArtifact = try fixture.store.artifactRecord(
            installationID: "bad-resume",
            artifactID: artifactID
        )
        let artifact = try #require(storedArtifact)
        #expect(artifact.resumeData == nil)
        #expect(artifact.receivedBytes == 0)
    }

    @Test
    func networkFailurePersistsStableFailureAndStartsNextQueuedInstall() async throws {
        let fixture = try DownloadFixture()
        let first = try productionManifest()
        let second = copy(first, id: LocalModelRevisionID(modelID: "after-failure", revision: 1))
        try await fixture.coordinator.enqueue(installationID: "failure", manifest: first)
        try await fixture.coordinator.enqueue(installationID: "next", manifest: second)
        try await eventually { fixture.transport.snapshot().starts.count == 1 }
        let task = try #require(fixture.transport.snapshot().starts.first?.taskIdentifier)

        fixture.transport.fail(
            taskIdentifier: task,
            failure: LLMFailure(code: "transport.offline", message: "private detail", retryable: true)
        )

        try await eventually {
            try fixture.store.installationSummary(installationID: "failure")?.state == .failed
        }
        let failedSummary = try fixture.store.installationSummary(installationID: "failure")
        let failed = try #require(failedSummary)
        #expect(failed.failureCode == "download.network_failed")
        try await eventually { fixture.transport.snapshot().starts.count == 2 }
        #expect(fixture.transport.snapshot().starts[1].request.installationID == "next")
    }

    @Test
    func failedDownloadRetriesFromZeroAndQueuedDownloadCancelsWithoutActiveTask() async throws {
        let fixture = try DownloadFixture()
        let first = try productionManifest()
        let second = copy(
            first,
            id: LocalModelRevisionID(modelID: "queued-cancel", revision: 1)
        )
        try await fixture.coordinator.enqueue(
            installationID: "retry",
            manifest: first
        )
        try await fixture.coordinator.enqueue(
            installationID: "queued",
            manifest: second
        )
        try await eventually { fixture.transport.snapshot().starts.count == 1 }
        try await fixture.coordinator.cancel(installationID: "queued")
        #expect(try fixture.store.installationSummary(installationID: "queued") == nil)

        let firstTask = try #require(
            fixture.transport.snapshot().starts.first?.taskIdentifier
        )
        fixture.transport.fail(
            taskIdentifier: firstTask,
            failure: LLMFailure(
                code: "transport.offline",
                message: "offline",
                retryable: true
            )
        )
        try await eventually {
            try fixture.store.installationSummary(installationID: "retry")?.state
                == .failed
        }
        try await fixture.coordinator.retry(
            installationID: "retry",
            manifest: first
        )
        try await eventually { fixture.transport.snapshot().starts.count == 2 }
        #expect(try fixture.store.installationSummary(
            installationID: "retry"
        )?.state == .downloading)
        let artifact = try #require(try fixture.store.artifactRecords(
            installationID: "retry"
        ).first)
        #expect(artifact.receivedBytes == 0)
    }

    @Test
    func restoreReattachesKnownTaskAndQuarantinesUnknownTaskOnTheSameStream() async throws {
        let fixture = try DownloadFixture(autoRestore: false)
        let manifest = try productionManifest()
        try fixture.seedDownloading(
            installationID: "restored",
            manifest: manifest,
            taskIdentifier: 41
        )
        fixture.transport.restored = [
            RestoredModelDownload(taskIdentifier: 41, installationID: "restored", artifactID: manifest.artifacts[0].artifactID),
            RestoredModelDownload(taskIdentifier: 99, installationID: "unknown", artifactID: "weights"),
        ]

        try await fixture.coordinator.restore(pendingCancellations: [])

        #expect(fixture.transport.snapshot().cancelledTaskIdentifiers == [99])
        fixture.transport.progress(taskIdentifier: 41, receivedBytes: 123, expectedBytes: manifest.artifacts[0].byteSize)
        try await eventually {
            try fixture.store.artifactRecord(
                installationID: "restored",
                artifactID: manifest.artifacts[0].artifactID
            )?.receivedBytes == 123
        }
        fixture.transport.fail(
            taskIdentifier: 41,
            failure: LLMFailure(code: "transport.closed", message: "closed", retryable: true)
        )
        try await eventually {
            try fixture.store.installationSummary(installationID: "restored")?.failureCode
                == "download.network_failed"
        }
    }

    @Test
    func restoredValidatorMismatchDiscardsOnlyThatArtifactAndRestartsSafely() async throws {
        let fixture = try DownloadFixture(autoRestore: false)
        let manifest = try productionManifest()
        let artifact = try #require(manifest.artifacts.first)
        try fixture.seedDownloading(
            installationID: "validator",
            manifest: manifest,
            taskIdentifier: 51
        )
        let storedValue = try fixture.store.artifactRecord(
            installationID: "validator",
            artifactID: artifact.artifactID
        )
        let stored = try #require(storedValue)
        _ = try fixture.store.updateArtifactTransfer(
            installationID: "validator",
            artifactID: artifact.artifactID,
            expectedStateRevision: stored.stateRevision,
            receivedBytes: 100,
            resumeData: Data([1, 2, 3]),
            etag: "etag-old",
            lastModified: "Fri, 11 Jul 2026 00:00:00 GMT",
            taskIdentifier: 51
        )
        fixture.transport.restored = [
            RestoredModelDownload(
                taskIdentifier: 51,
                installationID: "validator",
                artifactID: artifact.artifactID
            ),
        ]
        try await fixture.coordinator.restore(pendingCancellations: [])

        fixture.transport.complete(
            taskIdentifier: 51,
            stagedFileURL: try fixture.paths.stagingArtifact(
                installationID: "validator",
                relativePath: artifact.relativePath
            ),
            etag: "etag-new",
            lastModified: "Sat, 12 Jul 2026 00:00:00 GMT"
        )

        try await eventually { fixture.transport.snapshot().starts.count == 1 }
        let restarted = fixture.transport.snapshot().starts[0]
        #expect(restarted.request.installationID == "validator")
        #expect(restarted.request.artifactID == artifact.artifactID)
        #expect(restarted.resumeData == nil)
        let refreshedValue = try fixture.store.artifactRecord(
            installationID: "validator",
            artifactID: artifact.artifactID
        )
        let refreshed = try #require(refreshedValue)
        #expect(refreshed.receivedBytes == 0)
        #expect(refreshed.etag == nil)
        #expect(refreshed.lastModified == nil)
    }

    @Test
    func pendingCancellationConvergesAfterCrashBoundaries() async throws {
        for crashPoint in ModelDownloadCancellationCrashPoint.allCases {
            let fixture = try DownloadFixture(cancellationCrashPoint: crashPoint)
            let manifest = try productionManifest()
            try await fixture.coordinator.enqueue(installationID: "cancel-\(crashPoint.rawValue)", manifest: manifest)
            try await eventually { fixture.transport.snapshot().starts.count == 1 }
            do {
                try await fixture.coordinator.cancel(installationID: "cancel-\(crashPoint.rawValue)")
                Issue.record("expected injected cancellation crash")
            } catch let failure as LLMFailure {
                #expect(failure.code == "download.injected_cancellation_crash")
            }
            let operation = try #require(fixture.store.unfinishedFilesystemOperations().first)
            let taskIdentifier = try #require(operation.taskIdentifier)

            let recovering = ModelDownloadCoordinator(
                store: fixture.store,
                paths: fixture.paths,
                transport: fixture.transport
            )
            try await recovering.restore(pendingCancellations: [
                PendingTransportCancellation(
                    operationID: operation.operationID,
                    taskIdentifier: taskIdentifier,
                    installationID: operation.installationID
                ),
            ])

            #expect(try fixture.store.installationSummary(installationID: operation.installationID) == nil)
            #expect(try fixture.store.unfinishedFilesystemOperations().isEmpty)
        }
    }
}

private struct DownloadFixture {
    let root: URL
    let paths: LocalModelPaths
    let store: LocalModelStore
    let transport: FakeModelDownloadTransport
    let coordinator: ModelDownloadCoordinator

    init(
        autoRestore: Bool = true,
        cancellationCrashPoint: ModelDownloadCancellationCrashPoint? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "download-coordinator-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = try LocalModelPaths(root: root, backupExclusion: DownloadBackupRecorder())
        store = try LocalModelStore(
            fileURL: root.appending(path: "local-models.sqlite"),
            backupExclusion: DownloadBackupRecorder()
        )
        transport = FakeModelDownloadTransport()
        coordinator = ModelDownloadCoordinator(
            store: store,
            paths: paths,
            transport: transport,
            cancellationCrashPointForTesting: cancellationCrashPoint
        )
        _ = autoRestore
    }

    func seedDownloading(
        installationID: String,
        manifest: LocalModelRevisionManifest,
        taskIdentifier: Int
    ) throws {
        _ = try store.enqueueInstallation(
            installationID: installationID,
            modelRevision: manifest.id,
            rootPath: try paths.finalInstallation(installationID).path
        )
        let artifact = try #require(manifest.artifacts.first)
        try store.recordArtifact(
            installationID: installationID,
            artifactID: artifact.artifactID,
            relativePath: artifact.relativePath,
            downloadURL: artifact.downloadURL,
            expectedBytes: artifact.byteSize,
            artifactSHA256: artifact.artifactSHA256
        )
        let storedSummary = try store.installationSummary(installationID: installationID)
        let summary = try #require(storedSummary)
        _ = try store.transitionInstallation(
            installationID: installationID,
            expectedStateRevision: summary.stateRevision,
            to: .downloading
        )
        let storedRecord = try store.artifactRecord(
            installationID: installationID,
            artifactID: artifact.artifactID
        )
        let record = try #require(storedRecord)
        _ = try store.updateArtifactTransfer(
            installationID: installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: record.stateRevision,
            receivedBytes: 0,
            resumeData: nil,
            etag: nil,
            lastModified: nil,
            taskIdentifier: taskIdentifier
        )
    }
}

private final class FakeModelDownloadTransport: ModelDownloadTransport, @unchecked Sendable {
    struct Start: Equatable {
        let taskIdentifier: Int
        let request: ArtifactDownloadRequest
        let resumeData: Data?
    }

    struct Snapshot {
        let starts: [Start]
        let maximumActiveCount: Int
        let cancelledTaskIdentifiers: [Int]
    }

    let events: AsyncStream<ModelDownloadTransportEvent>
    private let continuation: AsyncStream<ModelDownloadTransportEvent>.Continuation
    private let lock = NSLock()
    private var starts: [Start] = []
    private var active: Set<Int> = []
    private var maximumActiveCount = 0
    private var cancelled: [Int] = []
    private var nextTaskIdentifier = 1
    var pauseData: Data?
    var rejectNextResumeData = false
    var restored: [RestoredModelDownload] = []

    init() {
        let pair = AsyncStream<ModelDownloadTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        events = pair.stream
        continuation = pair.continuation
    }

    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int {
        try lock.withLock {
            let task = nextTaskIdentifier
            nextTaskIdentifier += 1
            starts.append(Start(taskIdentifier: task, request: request, resumeData: resumeData))
            if resumeData != nil, rejectNextResumeData {
                rejectNextResumeData = false
                throw LLMFailure(
                    code: "download.resume_data_invalid",
                    message: "resume data rejected",
                    retryable: true
                )
            }
            active.insert(task)
            maximumActiveCount = max(maximumActiveCount, active.count)
            return task
        }
    }

    func restoredTasks() async throws -> [RestoredModelDownload] { lock.withLock { restored } }

    func pause(taskIdentifier: Int) async throws -> Data? {
        lock.withLock {
            active.remove(taskIdentifier)
            return pauseData
        }
    }

    func cancel(taskIdentifier: Int) async {
        lock.withLock {
            active.remove(taskIdentifier)
            cancelled.append(taskIdentifier)
        }
    }

    func setBackgroundEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) async {}

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                starts: starts,
                maximumActiveCount: maximumActiveCount,
                cancelledTaskIdentifiers: cancelled
            )
        }
    }

    func progress(taskIdentifier: Int, receivedBytes: UInt64, expectedBytes: UInt64) {
        continuation.yield(.progress(
            taskIdentifier: taskIdentifier,
            receivedBytes: receivedBytes,
            expectedBytes: expectedBytes
        ))
    }

    func complete(taskIdentifier: Int) {
        let start = lock.withLock { () -> Start? in
            active.remove(taskIdentifier)
            return starts.first { $0.taskIdentifier == taskIdentifier }
        }
        guard let start else { return }
        complete(
            taskIdentifier: taskIdentifier,
            stagedFileURL: start.request.stagingURL,
            etag: "etag-v1",
            lastModified: "Sat, 12 Jul 2026 00:00:00 GMT"
        )
    }

    func complete(
        taskIdentifier: Int,
        stagedFileURL: URL,
        etag: String?,
        lastModified: String?
    ) {
        _ = lock.withLock { active.remove(taskIdentifier) }
        continuation.yield(.completed(
            taskIdentifier: taskIdentifier,
            stagedFileURL: stagedFileURL,
            etag: etag,
            lastModified: lastModified
        ))
    }

    func fail(taskIdentifier: Int, failure: LLMFailure) {
        _ = lock.withLock { active.remove(taskIdentifier) }
        continuation.yield(.failed(taskIdentifier: taskIdentifier, failure: failure))
    }
}

private final class DownloadBackupRecorder: LocalBackupExclusionApplying, @unchecked Sendable {
    func excludeFromBackup(_ urls: [URL]) throws {}
}

private func productionManifest() throws -> LocalModelRevisionManifest {
    let resources = try OfficialModelCatalogResources.loadBundled()
    let catalog = try OfficialLocalModelCatalogVerifier.verify(
        envelope: resources.envelope,
        keyRing: resources.keyRing
    )
    return try #require(catalog.models[
        LocalModelRevisionID(modelID: "minicpm5-1b-q4-k-m", revision: 1)
    ])
}

private func copy(
    _ manifest: LocalModelRevisionManifest,
    id: LocalModelRevisionID
) -> LocalModelRevisionManifest {
    LocalModelRevisionManifest(
        id: id,
        displayName: manifest.displayName,
        family: manifest.family,
        engineID: manifest.engineID,
        modelFormat: manifest.modelFormat,
        artifacts: manifest.artifacts,
        installedByteSize: manifest.installedByteSize,
        minimumOSMajor: manifest.minimumOSMajor,
        supportedDeviceClasses: manifest.supportedDeviceClasses,
        estimatedMemoryClass: manifest.estimatedMemoryClass,
        declaredCapabilities: manifest.declaredCapabilities,
        parameterSchema: manifest.parameterSchema,
        parameterDefaults: manifest.parameterDefaults,
        loadTemplate: manifest.loadTemplate,
        chatTemplate: manifest.chatTemplate,
        toolCallCodecID: manifest.toolCallCodecID
    )
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition was not satisfied before timeout")
}
