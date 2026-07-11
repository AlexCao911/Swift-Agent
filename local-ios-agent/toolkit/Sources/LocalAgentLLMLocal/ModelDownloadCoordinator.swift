import Foundation
import LocalAgentLLMContracts

package enum ModelDownloadCancellationCrashPoint: String, CaseIterable, Sendable {
    case afterIntentPersisted = "after-intent-persisted"
    case afterTransportCancelled = "after-transport-cancelled"
    case afterStagingCleanup = "after-staging-cleanup"
}

package actor ModelDownloadCoordinator {
    private struct ActiveTransfer: Equatable, Sendable {
        let taskIdentifier: Int
        let installationID: String
        let artifactID: String
    }

    private let store: LocalModelStore
    private let paths: LocalModelPaths
    private let transport: any ModelDownloadTransport
    private let cancellationCrashPointForTesting: ModelDownloadCancellationCrashPoint?
    private var active: ActiveTransfer?
    private var bufferedEvents: [Int: [ModelDownloadTransportEvent]] = [:]

    package init(
        store: LocalModelStore,
        paths: LocalModelPaths,
        transport: any ModelDownloadTransport,
        cancellationCrashPointForTesting: ModelDownloadCancellationCrashPoint? = nil
    ) {
        self.store = store
        self.paths = paths
        self.transport = transport
        self.cancellationCrashPointForTesting = cancellationCrashPointForTesting
        let events = transport.events
        Task { [weak self] in
            for await event in events {
                await self?.receive(event)
            }
        }
    }

    package func enqueue(
        installationID: String,
        manifest: LocalModelRevisionManifest
    ) async throws {
        let finalPath = try paths.finalInstallation(installationID)
        if let existing = try store.installationRecord(installationID: installationID) {
            guard existing.modelRevision == manifest.id else {
                throw downloadFailure(
                    "download.installation_conflict",
                    "installation ID is already bound to another model revision"
                )
            }
        } else {
            _ = try store.enqueueInstallation(
                installationID: installationID,
                modelRevision: manifest.id,
                rootPath: finalPath.path
            )
        }
        let staging = try paths.stagingInstallation(installationID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for artifact in manifest.artifacts {
            try store.recordArtifact(
                installationID: installationID,
                artifactID: artifact.artifactID,
                relativePath: artifact.relativePath,
                downloadURL: artifact.downloadURL,
                expectedBytes: artifact.byteSize,
                artifactSHA256: artifact.artifactSHA256
            )
        }
        try await pump()
    }

    package func restore(
        pendingCancellations: [PendingTransportCancellation]
    ) async throws {
        let restored = try await transport.restoredTasks()

        for cancellation in pendingCancellations {
            try await convergeCancellation(cancellation, injectCrash: false)
        }

        var attached = false
        for task in restored where !pendingCancellations.contains(where: {
            $0.taskIdentifier == task.taskIdentifier
        }) {
            guard !attached,
                  let artifact = try store.artifactRecord(taskIdentifier: task.taskIdentifier),
                  artifact.installationID == task.installationID,
                  artifact.artifactID == task.artifactID
            else {
                await transport.cancel(taskIdentifier: task.taskIdentifier)
                continue
            }
            active = ActiveTransfer(
                taskIdentifier: task.taskIdentifier,
                installationID: task.installationID,
                artifactID: task.artifactID
            )
            attached = true
        }
        try await pump()
    }

    package func pause(installationID: String) async throws {
        guard let active, active.installationID == installationID else {
            throw downloadFailure("download.not_active", "installation has no active artifact transfer")
        }
        let resumeData = try await transport.pause(taskIdentifier: active.taskIdentifier)
        guard let artifact = try store.artifactRecord(
            installationID: active.installationID,
            artifactID: active.artifactID
        ) else { throw downloadFailure("download.artifact_missing", "active artifact is missing") }
        _ = try store.updateArtifactTransfer(
            installationID: artifact.installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: artifact.stateRevision,
            receivedBytes: artifact.receivedBytes,
            resumeData: resumeData,
            etag: artifact.etag,
            lastModified: artifact.lastModified,
            taskIdentifier: nil
        )
        guard let installation = try store.installationSummary(installationID: installationID) else {
            throw downloadFailure("download.installation_not_found", "installation is missing")
        }
        _ = try store.transitionInstallation(
            installationID: installationID,
            expectedStateRevision: installation.stateRevision,
            to: .paused
        )
        self.active = nil
    }

    package func resume(installationID: String) async throws {
        guard let installation = try store.installationSummary(installationID: installationID),
              installation.state == .paused
        else { throw downloadFailure("download.not_paused", "installation is not paused") }
        _ = try store.transitionInstallation(
            installationID: installationID,
            expectedStateRevision: installation.stateRevision,
            to: .downloading
        )
        try await pump()
    }

    package func cancel(installationID: String) async throws {
        guard let active, active.installationID == installationID else {
            throw downloadFailure("download.not_active", "installation has no active artifact transfer")
        }
        let operation = try store.createFilesystemOperation(
            operationID: "cancel-\(UUID().uuidString.lowercased())",
            installationID: installationID,
            kind: .cancelDownload,
            taskIdentifier: active.taskIdentifier
        )
        try injectCancellationCrash(.afterIntentPersisted)
        try await convergeCancellation(
            PendingTransportCancellation(
                operationID: operation.operationID,
                taskIdentifier: active.taskIdentifier,
                installationID: installationID
            ),
            injectCrash: true
        )
    }

    private func pump() async throws {
        guard active == nil else { return }
        for entry in try store.queuedInstallations() {
            guard var installation = try store.installationSummary(
                installationID: entry.installationID
            ) else { continue }
            switch installation.state {
            case .queued:
                installation = try store.transitionInstallation(
                    installationID: installation.installationID,
                    expectedStateRevision: installation.stateRevision,
                    to: .downloading
                )
            case .downloading:
                break
            case .paused:
                return
            case .failed, .verifying, .installed, .deleting:
                continue
            }
            let artifacts = try store.artifactRecords(installationID: installation.installationID)
            if let artifact = artifacts.first(where: { $0.receivedBytes < $0.expectedBytes }) {
                try await start(artifact)
                return
            }
            _ = try store.transitionInstallation(
                installationID: installation.installationID,
                expectedStateRevision: installation.stateRevision,
                to: .verifying
            )
            try store.removeQueuedInstallation(
                installationID: entry.installationID,
                expectedPosition: entry.position
            )
        }
    }

    private func start(_ artifact: LocalArtifactRecord) async throws {
        guard let url = URL(string: artifact.downloadURL) else {
            throw downloadFailure("download.artifact_url_invalid", "signed artifact URL is invalid")
        }
        let request = ArtifactDownloadRequest(
            installationID: artifact.installationID,
            artifactID: artifact.artifactID,
            url: url,
            expectedBytes: artifact.expectedBytes,
            stagingURL: try paths.stagingArtifact(
                installationID: artifact.installationID,
                relativePath: artifact.relativePath
            ),
            etag: artifact.etag,
            lastModified: artifact.lastModified
        )
        let taskIdentifier: Int
        do {
            taskIdentifier = try await transport.start(request, resumeData: artifact.resumeData)
        } catch let failure as LLMFailure where
            failure.code == "download.resume_data_invalid" && artifact.resumeData != nil {
            let revision = try store.updateArtifactTransfer(
                installationID: artifact.installationID,
                artifactID: artifact.artifactID,
                expectedStateRevision: artifact.stateRevision,
                receivedBytes: 0,
                resumeData: nil,
                etag: nil,
                lastModified: nil,
                taskIdentifier: nil
            )
            let cleared = LocalArtifactRecord(
                installationID: artifact.installationID,
                artifactID: artifact.artifactID,
                relativePath: artifact.relativePath,
                downloadURL: artifact.downloadURL,
                expectedBytes: artifact.expectedBytes,
                receivedBytes: 0,
                artifactSHA256: artifact.artifactSHA256,
                resumeData: nil,
                etag: nil,
                lastModified: nil,
                stateRevision: revision,
                taskIdentifier: nil
            )
            try await start(cleared)
            return
        }
        let revision = try store.updateArtifactTransfer(
            installationID: artifact.installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: artifact.stateRevision,
            receivedBytes: artifact.receivedBytes,
            resumeData: artifact.resumeData,
            etag: artifact.etag,
            lastModified: artifact.lastModified,
            taskIdentifier: taskIdentifier
        )
        active = ActiveTransfer(
            taskIdentifier: taskIdentifier,
            installationID: artifact.installationID,
            artifactID: artifact.artifactID
        )
        if let pending = bufferedEvents.removeValue(forKey: taskIdentifier) {
            for event in pending { await receive(event) }
        }
        _ = revision
    }

    private func receive(_ event: ModelDownloadTransportEvent) async {
        let taskIdentifier = event.taskIdentifier
        guard let artifact = try? store.artifactRecord(taskIdentifier: taskIdentifier) else {
            bufferedEvents[taskIdentifier, default: []].append(event)
            return
        }
        do {
            switch event {
            case let .progress(_, receivedBytes, expectedBytes):
                try handleProgress(
                    artifact: artifact,
                    receivedBytes: receivedBytes,
                    transportExpectedBytes: expectedBytes
                )
            case let .completed(_, stagedFileURL, etag, lastModified):
                try await handleCompletion(
                    artifact: artifact,
                    stagedFileURL: stagedFileURL,
                    etag: etag,
                    lastModified: lastModified
                )
            case let .failed(_, failure) where failure.code == "download.resume_data_invalid":
                try await restartWithoutResumeData(artifact: artifact)
            case .failed:
                try await handleFailure(artifact: artifact)
            }
        } catch {
            try? await handleFailure(artifact: artifact)
        }
    }

    private func handleProgress(
        artifact: LocalArtifactRecord,
        receivedBytes: UInt64,
        transportExpectedBytes: UInt64
    ) throws {
        guard transportExpectedBytes == artifact.expectedBytes else {
            throw downloadFailure("download.validator_mismatch", "server length changed")
        }
        _ = try store.updateArtifactTransfer(
            installationID: artifact.installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: artifact.stateRevision,
            receivedBytes: receivedBytes,
            resumeData: artifact.resumeData,
            etag: artifact.etag,
            lastModified: artifact.lastModified,
            taskIdentifier: artifact.taskIdentifier
        )
    }

    private func handleCompletion(
        artifact: LocalArtifactRecord,
        stagedFileURL: URL,
        etag: String?,
        lastModified: String?
    ) async throws {
        let expectedURL = try paths.stagingArtifact(
            installationID: artifact.installationID,
            relativePath: artifact.relativePath
        )
        guard stagedFileURL.standardizedFileURL == expectedURL.standardizedFileURL else {
            throw downloadFailure("download.staging_path_mismatch", "transport completed outside staging")
        }
        let validatorChanged = (artifact.etag != nil && artifact.etag != etag)
            || (artifact.lastModified != nil && artifact.lastModified != lastModified)
        if validatorChanged {
            try? FileManager.default.removeItem(at: expectedURL)
            _ = try store.updateArtifactTransfer(
                installationID: artifact.installationID,
                artifactID: artifact.artifactID,
                expectedStateRevision: artifact.stateRevision,
                receivedBytes: 0,
                resumeData: nil,
                etag: nil,
                lastModified: nil,
                taskIdentifier: nil
            )
            active = nil
            try await pump()
            return
        }
        _ = try store.updateArtifactTransfer(
            installationID: artifact.installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: artifact.stateRevision,
            receivedBytes: artifact.expectedBytes,
            resumeData: nil,
            etag: etag,
            lastModified: lastModified,
            taskIdentifier: nil
        )
        active = nil
        try await pump()
    }

    private func handleFailure(artifact: LocalArtifactRecord) async throws {
        if artifact.taskIdentifier != nil {
            _ = try store.updateArtifactTransfer(
                installationID: artifact.installationID,
                artifactID: artifact.artifactID,
                expectedStateRevision: artifact.stateRevision,
                receivedBytes: artifact.receivedBytes,
                resumeData: artifact.resumeData,
                etag: artifact.etag,
                lastModified: artifact.lastModified,
                taskIdentifier: nil
            )
        }
        if let installation = try store.installationSummary(installationID: artifact.installationID),
           installation.state == .downloading {
            _ = try store.transitionInstallation(
                installationID: installation.installationID,
                expectedStateRevision: installation.stateRevision,
                to: .failed,
                failureCode: "download.network_failed"
            )
        }
        if active?.taskIdentifier == artifact.taskIdentifier {
            active = nil
        }
        try await pump()
    }

    private func restartWithoutResumeData(artifact: LocalArtifactRecord) async throws {
        _ = try store.updateArtifactTransfer(
            installationID: artifact.installationID,
            artifactID: artifact.artifactID,
            expectedStateRevision: artifact.stateRevision,
            receivedBytes: 0,
            resumeData: nil,
            etag: nil,
            lastModified: nil,
            taskIdentifier: nil
        )
        if active?.taskIdentifier == artifact.taskIdentifier { active = nil }
        try await pump()
    }

    private func convergeCancellation(
        _ cancellation: PendingTransportCancellation,
        injectCrash: Bool
    ) async throws {
        await transport.cancel(taskIdentifier: cancellation.taskIdentifier)
        if injectCrash { try injectCancellationCrash(.afterTransportCancelled) }
        let staging = try paths.stagingInstallation(cancellation.installationID)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        if injectCrash { try injectCancellationCrash(.afterStagingCleanup) }
        guard let operation = try store.unfinishedFilesystemOperations().first(where: {
            $0.operationID == cancellation.operationID
        }) else {
            if active?.taskIdentifier == cancellation.taskIdentifier { active = nil }
            return
        }
        if operation.state == .pending {
            try store.transitionFilesystemOperation(
                operationID: operation.operationID,
                from: .pending,
                to: .filesystemApplied
            )
        }
        try store.completeDownloadCancellation(operationID: operation.operationID)
        if active?.taskIdentifier == cancellation.taskIdentifier { active = nil }
        try await pump()
    }

    private func injectCancellationCrash(
        _ point: ModelDownloadCancellationCrashPoint
    ) throws {
        guard cancellationCrashPointForTesting == point else { return }
        throw downloadFailure(
            "download.injected_cancellation_crash",
            "injected cancellation crash at \(point.rawValue)"
        )
    }
}

private extension ModelDownloadTransportEvent {
    var taskIdentifier: Int {
        switch self {
        case let .progress(taskIdentifier, _, _),
             let .completed(taskIdentifier, _, _, _),
             let .failed(taskIdentifier, _):
            taskIdentifier
        }
    }
}

private func downloadFailure(_ code: String, _ message: String) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: false)
}
