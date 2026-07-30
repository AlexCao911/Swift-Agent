import Foundation
import LocalAgentBridge

@MainActor
protocol RustAgentSnapshotProviding {
    func snapshot(
        conversationStreamID: String?,
        modelContextWindow: ModelContextWindowDTO
    ) async throws -> RunStartSnapshotDTO
}

extension RustAgentInputSnapshotProvider: RustAgentSnapshotProviding {}

@MainActor
protocol RustAgentRunCancelling {
    func cancelRun(runId: String) async throws -> RuntimeEventDTO
}

extension RustExecutionBridgeClient: RustAgentRunCancelling {}

@MainActor
protocol RustAgentModelRunPreparing {
    func modelContextWindow(
        agentProfileID: String,
        agentProfileRevisionID: UInt64
    ) async throws -> ModelContextWindowDTO

    func prepareModelRun(
        runID: String,
        agentProfileID: String,
        agentProfileRevisionID: UInt64
    ) async throws

    func finishModelRun(runID: String) async
}

@MainActor
final class RustAgentCoordinator: ObservableObject {
    typealias ReportRunID = @MainActor @Sendable (_ runID: String) -> Void

    private let conversation: any ConversationBridgeClient
    private let snapshots: any RustAgentSnapshotProviding
    private let models: any RustAgentModelRunPreparing
    private let projections: ProjectionFeedController
    private let cancellation: (any RustAgentRunCancelling)?
    private var pendingRunIDs: Set<String> = []
    private var cancellationRequestedRunIDs: Set<String> = []

    init(
        conversation: any ConversationBridgeClient,
        snapshots: any RustAgentSnapshotProviding,
        models: any RustAgentModelRunPreparing,
        projections: ProjectionFeedController,
        cancellation: (any RustAgentRunCancelling)? = nil
    ) {
        self.conversation = conversation
        self.snapshots = snapshots
        self.models = models
        self.projections = projections
        self.cancellation = cancellation
    }

    @discardableResult
    func send(
        requestID: String,
        conversationStreamID: String,
        clientMessageID: String,
        text: String,
        attachments: [TranscriptAttachmentReferenceDTO],
        agentProfileID: String,
        agentProfileRevisionID: UInt64,
        reportRunID: @escaping ReportRunID = { _ in }
    ) async throws -> TranscriptCommandResultDTO {
        try Task.checkCancellation()
        let window = try await models.modelContextWindow(
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID
        )
        try Task.checkCancellation()
        let snapshot = try await snapshots.snapshot(
            conversationStreamID: conversationStreamID,
            modelContextWindow: window
        )
        try Task.checkCancellation()
        return try await submitRunCommand(
            .send(
                requestID: requestID,
                conversationStreamID: conversationStreamID,
                clientMessageID: clientMessageID,
                text: text,
                attachments: attachments,
                runStartSnapshot: snapshot
            ),
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID,
            reportRunID: reportRunID
        )
    }

    @discardableResult
    func retry(
        requestID: String,
        conversationStreamID: String,
        anchorEventID: String,
        agentProfileID: String,
        agentProfileRevisionID: UInt64,
        reportRunID: @escaping ReportRunID = { _ in }
    ) async throws -> TranscriptCommandResultDTO {
        try Task.checkCancellation()
        let window = try await models.modelContextWindow(
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID
        )
        try Task.checkCancellation()
        let snapshot = try await snapshots.snapshot(
            conversationStreamID: conversationStreamID,
            modelContextWindow: window
        )
        try Task.checkCancellation()
        return try await submitRunCommand(
            .retryFrom(
                requestID: requestID,
                conversationStreamID: conversationStreamID,
                anchorEventID: anchorEventID,
                runStartSnapshot: snapshot
            ),
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID,
            reportRunID: reportRunID
        )
    }

    @discardableResult
    func edit(
        requestID: String,
        conversationStreamID: String,
        targetEventID: String,
        replacementText: String,
        replacementAttachments: [TranscriptAttachmentReferenceDTO],
        agentProfileID: String,
        agentProfileRevisionID: UInt64,
        reportRunID: @escaping ReportRunID = { _ in }
    ) async throws -> TranscriptCommandResultDTO {
        try Task.checkCancellation()
        let window = try await models.modelContextWindow(
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID
        )
        try Task.checkCancellation()
        let snapshot = try await snapshots.snapshot(
            conversationStreamID: conversationStreamID,
            modelContextWindow: window
        )
        try Task.checkCancellation()
        return try await submitRunCommand(
            .editMessage(
                requestID: requestID,
                conversationStreamID: conversationStreamID,
                targetEventID: targetEventID,
                replacementText: replacementText,
                replacementAttachments: replacementAttachments,
                runStartSnapshot: snapshot
            ),
            agentProfileID: agentProfileID,
            agentProfileRevisionID: agentProfileRevisionID,
            reportRunID: reportRunID
        )
    }

    @discardableResult
    func submit(
        _ command: TranscriptCommandDTO
    ) async throws -> TranscriptCommandResultDTO {
        precondition(!command.startsRun)
        try projections.ensureFeed(
            conversationStreamID: command.conversationStreamID
        )
        let result: TranscriptCommandResultDTO
        do {
            result = try await conversation.submitTranscriptCommand(command)
        } catch {
            await projections.stopFeedIfUnmanaged(
                conversationStreamID: command.conversationStreamID
            )
            throw error
        }
        try projections.ensureFeed(
            conversationStreamID: command.conversationStreamID,
            temporaryThroughSequence: result.acceptedSequence
        )
        return result
    }

    func startProjection(conversationStreamID: String) throws {
        try projections.selectCurrentConversationSynchronously(
            conversationStreamID
        )
    }

    func restoreSessions() async throws {
        projections.restoreSessions(try await conversation.listSessions())
    }

    func cancel(runID: String) async throws {
        cancellationRequestedRunIDs.insert(runID)
        guard let cancellation else {
            throw RustAgentCoordinatorError(
                message: "Rust Agent cancellation is unavailable"
            )
        }
        do {
            _ = try await cancellation.cancelRun(runId: runID)
        } catch {
            guard pendingRunIDs.contains(runID) else { throw error }
        }
    }

    func selectConversation(
        conversationStreamID: String
    ) async throws {
        try await projections.selectCurrentConversation(
            conversationStreamID
        )
    }

    @discardableResult
    func createBranch(
        requestID: String,
        conversationStreamID: String,
        anchorEventID: String,
        newConversationStreamID: String
    ) async throws -> TranscriptCommandResultDTO {
        try projections.ensureFeed(
            conversationStreamID: newConversationStreamID
        )
        do {
            return try await submit(.createBranch(
                requestID: requestID,
                conversationStreamID: conversationStreamID,
                anchorEventID: anchorEventID,
                newConversationStreamID: newConversationStreamID
            ))
        } catch {
            await projections.stopFeed(
                conversationStreamID: newConversationStreamID
            )
            throw error
        }
    }

    func reconcileProjectionFeeds(
        runningConversationIDs: Set<String>,
        currentConversationID: String?
    ) async {
        await projections.reconcilePersistentFeeds(
            runningConversationIDs: runningConversationIDs,
            currentConversationID: currentConversationID
        )
    }

    private func submitRunCommand(
        _ command: TranscriptCommandDTO,
        agentProfileID: String,
        agentProfileRevisionID: UInt64,
        reportRunID: @escaping ReportRunID
    ) async throws -> TranscriptCommandResultDTO {
        guard let predictedRunID = try command.predictedRunID() else {
            preconditionFailure("run command did not produce a run ID")
        }
        pendingRunIDs.insert(predictedRunID)
        defer {
            pendingRunIDs.remove(predictedRunID)
            cancellationRequestedRunIDs.remove(predictedRunID)
        }
        reportRunID(predictedRunID)
        var acceptedByRust = false
        do {
            try checkCancellation(runID: predictedRunID)
            try await models.prepareModelRun(
                runID: predictedRunID,
                agentProfileID: agentProfileID,
                agentProfileRevisionID: agentProfileRevisionID
            )
            try checkCancellation(runID: predictedRunID)
            try projections.markRunStarted(
                conversationStreamID: command.conversationStreamID
            )
            try checkCancellation(runID: predictedRunID)
            let result = try await conversation.submitTranscriptCommand(command)
            acceptedByRust = true
            guard result.runID == predictedRunID else {
                throw RustAgentCoordinatorError(
                    message: "Rust returned an unexpected run identity"
                )
            }
            try checkCancellation(runID: predictedRunID)
            return result
        } catch {
            if acceptedByRust {
                if let cancellation {
                    _ = try? await cancellation.cancelRun(
                        runId: predictedRunID
                    )
                }
            } else {
                await models.finishModelRun(runID: predictedRunID)
                await projections.markRunFinished(
                    conversationStreamID: command.conversationStreamID
                )
            }
            throw error
        }
    }

    private func checkCancellation(runID: String) throws {
        if Task.isCancelled || cancellationRequestedRunIDs.contains(runID) {
            throw CancellationError()
        }
    }
}

struct RustAgentCoordinatorError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
