import Foundation
import LocalAgentLLMContracts

package final class URLSessionModelDownloadTransport: NSObject, ModelDownloadTransport, @unchecked Sendable {
    private struct TaskMetadata: Codable, Sendable {
        let installationID: String
        let artifactID: String
        let expectedBytes: UInt64
        let stagingPath: String
        let usedResumeData: Bool?
    }

    package let events: AsyncStream<ModelDownloadTransportEvent>

    private let continuation: AsyncStream<ModelDownloadTransportEvent>.Continuation
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var metadataByTask: [Int: TaskMetadata] = [:]
    private var copiedCompletions: Set<Int> = []
    private var intentionalCancellations: Set<Int> = []
    private var backgroundEventsCompletionHandler: (@Sendable () -> Void)?
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
    )

    package init(identifier: String? = nil) {
        let pair = AsyncStream<ModelDownloadTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        events = pair.stream
        continuation = pair.continuation
        let stableIdentifier = identifier ?? [
            Bundle.main.bundleIdentifier ?? "local-agent",
            "local-model-downloads.v1",
        ].joined(separator: ".")
#if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: stableIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        self.configuration = configuration
#else
        _ = stableIdentifier
        self.configuration = .default
#endif
        super.init()
    }

    package func start(
        _ request: ArtifactDownloadRequest,
        resumeData: Data?
    ) async throws -> Int {
        try FileManager.default.createDirectory(
            at: request.stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let task: URLSessionDownloadTask
        if let resumeData {
            guard !resumeData.isEmpty else {
                throw transportFailure(
                    "download.resume_data_invalid",
                    "resume data is empty",
                    retryable: true
                )
            }
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "GET"
            urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
            task = session.downloadTask(with: urlRequest)
        }
        let metadata = TaskMetadata(
            installationID: request.installationID,
            artifactID: request.artifactID,
            expectedBytes: request.expectedBytes,
            stagingPath: request.stagingURL.path,
            usedResumeData: resumeData != nil
        )
        task.taskDescription = try String(
            data: JSONEncoder().encode(metadata),
            encoding: .utf8
        ).unwrap(or: transportFailure(
            "download.task_metadata_invalid",
            "task metadata is not UTF-8",
            retryable: false
        ))
        lock.withLock { metadataByTask[task.taskIdentifier] = metadata }
        task.resume()
        return task.taskIdentifier
    }

    package func restoredTasks() async throws -> [RestoredModelDownload] {
        let tasks = await session.allTasks
        var restored: [RestoredModelDownload] = []
        for task in tasks {
            guard task is URLSessionDownloadTask,
                  let metadata = try decodeMetadata(task.taskDescription)
            else {
                task.cancel()
                continue
            }
            lock.withLock { metadataByTask[task.taskIdentifier] = metadata }
            restored.append(RestoredModelDownload(
                taskIdentifier: task.taskIdentifier,
                installationID: metadata.installationID,
                artifactID: metadata.artifactID
            ))
        }
        return restored.sorted { $0.taskIdentifier < $1.taskIdentifier }
    }

    package func pause(taskIdentifier: Int) async throws -> Data? {
        guard let task = await task(identifier: taskIdentifier) as? URLSessionDownloadTask else {
            throw transportFailure(
                "download.task_not_found",
                "background download task is missing",
                retryable: true
            )
        }
        _ = lock.withLock { intentionalCancellations.insert(taskIdentifier) }
        return await withCheckedContinuation { continuation in
            task.cancel { resumeData in continuation.resume(returning: resumeData) }
        }
    }

    package func cancel(taskIdentifier: Int) async {
        guard let task = await task(identifier: taskIdentifier) else { return }
        _ = lock.withLock { intentionalCancellations.insert(taskIdentifier) }
        task.cancel()
    }

    package func setBackgroundEventsCompletionHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async {
        lock.withLock { backgroundEventsCompletionHandler = handler }
    }

    private func task(identifier: Int) async -> URLSessionTask? {
        await session.allTasks.first { $0.taskIdentifier == identifier }
    }

    private func decodeMetadata(_ description: String?) throws -> TaskMetadata? {
        guard let description, let data = description.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(TaskMetadata.self, from: data)
    }

    private func metadata(for task: URLSessionTask) -> TaskMetadata? {
        if let value = lock.withLock({ metadataByTask[task.taskIdentifier] }) { return value }
        return try? decodeMetadata(task.taskDescription)
    }
}

extension URLSessionModelDownloadTransport: URLSessionDownloadDelegate {
    package func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let metadata = metadata(for: downloadTask), totalBytesWritten >= 0 else { return }
        continuation.yield(.progress(
            taskIdentifier: downloadTask.taskIdentifier,
            receivedBytes: UInt64(totalBytesWritten),
            expectedBytes: metadata.expectedBytes
        ))
    }

    package func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let metadata = metadata(for: downloadTask) else {
            continuation.yield(.failed(
                taskIdentifier: downloadTask.taskIdentifier,
                failure: transportFailure(
                    "download.task_metadata_invalid",
                    "download task metadata is missing",
                    retryable: false
                )
            ))
            return
        }
        let stagingURL = URL(fileURLWithPath: metadata.stagingPath)
        do {
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
            try FileManager.default.copyItem(at: location, to: stagingURL)
            _ = lock.withLock { copiedCompletions.insert(downloadTask.taskIdentifier) }
            let response = downloadTask.response as? HTTPURLResponse
            continuation.yield(.completed(
                taskIdentifier: downloadTask.taskIdentifier,
                stagedFileURL: stagingURL,
                etag: response?.value(forHTTPHeaderField: "ETag"),
                lastModified: response?.value(forHTTPHeaderField: "Last-Modified")
            ))
        } catch {
            continuation.yield(.failed(
                taskIdentifier: downloadTask.taskIdentifier,
                failure: transportFailure(
                    "download.staging_copy_failed",
                    "downloaded file could not be copied into staging",
                    retryable: true
                )
            ))
        }
    }
}

extension URLSessionModelDownloadTransport: URLSessionTaskDelegate {
    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let copied = lock.withLock { copiedCompletions.remove(task.taskIdentifier) != nil }
        let intentionallyCancelled = lock.withLock {
            intentionalCancellations.remove(task.taskIdentifier) != nil
        }
        defer { _ = lock.withLock { metadataByTask.removeValue(forKey: task.taskIdentifier) } }
        guard !copied, !intentionallyCancelled, error != nil else { return }
        let metadata = metadata(for: task)
        let code = metadata?.usedResumeData == true
            && task.countOfBytesReceived == 0
            && task.response == nil
            ? "download.resume_data_invalid" : "download.network_failed"
        continuation.yield(.failed(
            taskIdentifier: task.taskIdentifier,
            failure: transportFailure(code, "background download failed", retryable: true)
        ))
    }

    package func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { backgroundEventsCompletionHandler = nil }
            return backgroundEventsCompletionHandler
        }
        handler?()
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

private func transportFailure(
    _ code: String,
    _ message: String,
    retryable: Bool
) -> LLMFailure {
    LLMFailure(code: code, message: message, retryable: retryable)
}
