import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import XCTest
@testable import LocalAgentApp

@MainActor
final class RustAgentCoordinatorTests: XCTestCase {
    func testSendInstallsFeedAndBindsPredictedRunBeforeRustCommand() async throws {
        let conversation = RecordingTranscriptClient()
        let chatStore = ChatStore()
        let applier = ChatStoreProjectionApplier(
            store: chatStore,
            persistence: try TranscriptProjectionStore(fileURL: nil)
        )
        let feeds = ProjectionFeedController(
            client: conversation,
            applier: applier
        )
        let models = RecordingModelPreparation()
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: StaticSnapshotProvider(),
            models: models,
            projections: feeds
        )

        let result = try await coordinator.send(
            requestID: "request-1",
            conversationStreamID: "conversation-1",
            clientMessageID: "client-message-1",
            text: "hello",
            attachments: [],
            agentProfileID: "profile-1",
            agentProfileRevisionID: 1
        )

        let submitted = try XCTUnwrap(conversation.submittedCommand)
        let predicted = try XCTUnwrap(submitted.predictedRunID())
        XCTAssertEqual(result.runID, predicted)
        XCTAssertEqual(models.preparedRunIDs, [predicted])
        XCTAssertTrue(conversation.feedWasInstalledBeforeSubmit)
        XCTAssertEqual(feeds.observedConversationIDs, ["conversation-1"])
        await feeds.stopAll()
    }

    func testDormantMutationAlsoInstallsAFeedBeforeSubmitting() async throws {
        let conversation = RecordingTranscriptClient()
        let applier = ChatStoreProjectionApplier(
            store: ChatStore(),
            persistence: try TranscriptProjectionStore(fileURL: nil)
        )
        let feeds = ProjectionFeedController(
            client: conversation,
            applier: applier
        )
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: StaticSnapshotProvider(),
            models: RecordingModelPreparation(),
            projections: feeds
        )

        _ = try await coordinator.submit(.archiveConversation(
            requestID: "archive-1",
            conversationStreamID: "dormant"
        ))

        XCTAssertTrue(conversation.feedWasInstalledBeforeSubmit)
        XCTAssertEqual(feeds.observedConversationIDs, ["dormant"])
        await feeds.stopAll()
    }
}

@MainActor
private struct StaticSnapshotProvider: RustAgentSnapshotProviding {
    func snapshot(
        conversationStreamID _: String?,
        modelContextWindow: ModelContextWindowDTO
    ) async throws -> RunStartSnapshotDTO {
        try RunStartSnapshotDTO.make(
            orderedPromptDocuments: [],
            skillDescriptors: [],
            orderedToolDefinitions: [],
            modelContextWindow: modelContextWindow
        )
    }
}

@MainActor
private final class RecordingModelPreparation: RustAgentModelRunPreparing {
    private(set) var preparedRunIDs: [String] = []

    func modelContextWindow(
        agentProfileID _: String,
        agentProfileRevisionID _: UInt64
    ) async throws -> ModelContextWindowDTO {
        ModelContextWindowDTO(
            contextWindowTokens: 32_768,
            maxOutputTokens: 4_096
        )
    }

    func prepareModelRun(
        runID: String,
        agentProfileID _: String,
        agentProfileRevisionID _: UInt64
    ) async throws {
        preparedRunIDs.append(runID)
    }

    func finishModelRun(runID _: String) async {}
}

private final class RecordingTranscriptClient:
    ConversationBridgeClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var feedCount = 0
    private(set) var submittedCommand: TranscriptCommandDTO?
    private(set) var feedWasInstalledBeforeSubmit = false

    func submitTranscriptCommand(
        _ command: TranscriptCommandDTO
    ) async throws -> TranscriptCommandResultDTO {
        lock.withLock {
            submittedCommand = command
            feedWasInstalledBeforeSubmit = feedCount > 0
        }
        return TranscriptCommandResultDTO(
            conversationStreamID: command.conversationStreamID,
            acceptedSequence: 1,
            runID: try command.predictedRunID()
        )
    }

    func observeTranscriptProjections(
        subscriptionID _: String,
        conversationStreamID _: String,
        afterSequence _: UInt64
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error> {
        lock.withLock {
            feedCount += 1
        }
        return AsyncThrowingStream { _ in }
    }

    func cancelTranscriptProjectionSubscription(
        subscriptionID _: String
    ) async {}

    func listSessions() async throws -> [ConversationSummaryDTO] { [] }

    func prepareUserTurn(
        _ request: PrepareUserTurnRequestDTO
    ) async throws -> PreparedUserTurnDTO {
        throw TestCoordinatorFailure()
    }

    func activeBranch(
        sessionId _: String,
        leafId _: String?
    ) async throws -> [RuntimeEventDTO] { [] }

    func forkSession(sessionId _: String, leafId _: String) async throws -> String {
        throw TestCoordinatorFailure()
    }

    func archiveSession(sessionId _: String) async throws {}
    func renameSession(sessionId _: String, title _: String) async throws {}
    func deleteSession(sessionId _: String) async throws {}

    func commitAssistantResult(
        _ request: CommitAssistantResultRequestDTO
    ) async throws -> ConversationCommitResultDTO {
        throw TestCoordinatorFailure()
    }
}

private struct TestCoordinatorFailure: Error {}
