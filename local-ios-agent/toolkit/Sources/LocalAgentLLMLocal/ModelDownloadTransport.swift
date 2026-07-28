import Foundation
import LocalAgentLLMContracts

package protocol ModelDownloadTransport: Sendable {
    var events: AsyncStream<ModelDownloadTransportEvent> { get }
    func start(_ request: ArtifactDownloadRequest, resumeData: Data?) async throws -> Int
    func restoredTasks() async throws -> [RestoredModelDownload]
    func pause(taskIdentifier: Int) async throws -> Data?
    func cancel(taskIdentifier: Int) async
    func setBackgroundEventsCompletionHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async
}

package struct ArtifactDownloadRequest: Equatable, Sendable {
    let installationID: String
    let artifactID: String
    let url: URL
    let expectedBytes: UInt64
    let stagingURL: URL
    let etag: String?
    let lastModified: String?
}

package enum ModelDownloadTransportEvent: Equatable, Sendable {
    case progress(taskIdentifier: Int, receivedBytes: UInt64, expectedBytes: UInt64)
    case completed(
        taskIdentifier: Int,
        stagedFileURL: URL,
        etag: String?,
        lastModified: String?
    )
    case failed(taskIdentifier: Int, failure: LLMFailure)
}

package struct RestoredModelDownload: Equatable, Sendable {
    let taskIdentifier: Int
    let installationID: String
    let artifactID: String
}

package struct PendingTransportCancellation: Equatable, Sendable {
    let operationID: String
    let taskIdentifier: Int?
    let installationID: String
}
