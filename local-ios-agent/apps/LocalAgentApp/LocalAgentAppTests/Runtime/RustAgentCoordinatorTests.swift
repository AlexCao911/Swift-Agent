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

    func testConversationSwitchReleasesPreviouslyOpenedIdleFeed() async throws {
        let conversation = RecordingTranscriptClient()
        let feeds = ProjectionFeedController(
            client: conversation,
            applier: ChatStoreProjectionApplier(
                store: ChatStore(),
                persistence: try TranscriptProjectionStore(fileURL: nil)
            )
        )
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: StaticSnapshotProvider(),
            models: RecordingModelPreparation(),
            projections: feeds
        )
        try coordinator.startProjection(conversationStreamID: "conversation-a")

        try await coordinator.selectConversation(
            conversationStreamID: "conversation-b"
        )

        XCTAssertEqual(feeds.observedConversationIDs, ["conversation-b"])
        XCTAssertEqual(conversation.cancelledFeedCount, 1)
        await feeds.stopAll()
    }

    func testStartingFeedReplaysPersistedProjectionBeforeSubscribing() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(
            path: "projection-feed-\(UUID().uuidString).sqlite"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let persistence = try TranscriptProjectionStore(fileURL: fileURL)
        let first = ChatStoreProjectionApplier(
            store: ChatStore(),
            persistence: persistence
        )
        _ = try first.apply(TranscriptProjectionEventDTO(
            conversationStreamID: "conversation-restored",
            sequence: 1,
            eventID: "user-restored",
            runID: "run-restored",
            kind: .userMessage,
            payload: try .object(entries: [
                .init(
                    name: "command",
                    value: try .object(entries: [
                        .init(name: "text", value: .string("restored text")),
                    ])
                ),
            ])
        ))
        let chatStore = ChatStore()
        let feeds = ProjectionFeedController(
            client: RecordingTranscriptClient(),
            applier: ChatStoreProjectionApplier(
                store: chatStore,
                persistence: try TranscriptProjectionStore(fileURL: fileURL)
            )
        )

        try feeds.selectCurrentConversationSynchronously(
            "conversation-restored"
        )

        XCTAssertEqual(
            chatStore.projectedMessages(
                conversationStreamID: "conversation-restored"
            ).map(\.text),
            ["restored text"]
        )
        await feeds.stopAll()
    }

    func testRestoreSessionsInitializesConversationListFromRust() async throws {
        let conversation = RecordingTranscriptClient()
        conversation.sessions = [
            ConversationSummaryDTO(
                sessionId: "conversation-dormant",
                title: "Restored",
                activeLeafId: "leaf",
                lastEventId: "event",
                lastUpdatedSequence: 9,
                lastUpdatedAtMillis: 1_000,
                searchText: "restored"
            ),
        ]
        let chatStore = ChatStore()
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: StaticSnapshotProvider(),
            models: RecordingModelPreparation(),
            projections: ProjectionFeedController(
                client: conversation,
                applier: ChatStoreProjectionApplier(
                    store: chatStore,
                    persistence: try TranscriptProjectionStore(fileURL: nil)
                )
            )
        )

        try await coordinator.restoreSessions()

        XCTAssertEqual(chatStore.sessions.map(\.sessionId), ["conversation-dormant"])
        XCTAssertEqual(chatStore.sessions.first?.title, "Restored")
    }

    func testFailedBranchClosesItsPreinstalledTargetFeed() async throws {
        let conversation = RecordingTranscriptClient()
        conversation.submitError = TestCoordinatorFailure()
        let feeds = ProjectionFeedController(
            client: conversation,
            applier: ChatStoreProjectionApplier(
                store: ChatStore(),
                persistence: try TranscriptProjectionStore(fileURL: nil)
            )
        )
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: StaticSnapshotProvider(),
            models: RecordingModelPreparation(),
            projections: feeds
        )

        do {
            _ = try await coordinator.createBranch(
                requestID: "branch-request",
                conversationStreamID: "conversation-a",
                anchorEventID: "user-1",
                newConversationStreamID: "conversation-branch"
            )
            XCTFail("expected branch submission to fail")
        } catch {}

        XCTAssertFalse(
            feeds.observedConversationIDs.contains("conversation-branch")
        )
        XCTAssertTrue(feeds.observedConversationIDs.isEmpty)
        await feeds.stopAll()
    }

    func testModelPreparationFailureDoesNotLeaveConversationRunning() async throws {
        let conversation = RecordingTranscriptClient()
        let feeds = ProjectionFeedController(
            client: conversation,
            applier: ChatStoreProjectionApplier(
                store: ChatStore(),
                persistence: try TranscriptProjectionStore(fileURL: nil)
            )
        )
        let models = RecordingModelPreparation()
        models.prepareError = TestCoordinatorFailure()
        let coordinator = RustAgentCoordinator(
            conversation: conversation,
            snapshots: StaticSnapshotProvider(),
            models: models,
            projections: feeds
        )

        do {
            _ = try await coordinator.send(
                requestID: "request-fails-before-submit",
                conversationStreamID: "conversation-a",
                clientMessageID: "message-a",
                text: "hello",
                attachments: [],
                agentProfileID: "profile-a",
                agentProfileRevisionID: 1
            )
            XCTFail("expected model preparation to fail")
        } catch {}

        XCTAssertNil(conversation.submittedCommand)
        XCTAssertTrue(feeds.observedConversationIDs.isEmpty)
        XCTAssertEqual(models.finishedRunIDs.count, 1)
    }

    func testTemporaryFeedClosesWhenProjectionArrivedBeforeTargetWasRegistered() async throws {
        let conversation = RecordingTranscriptClient()
        let feeds = ProjectionFeedController(
            client: conversation,
            applier: ChatStoreProjectionApplier(
                store: ChatStore(),
                persistence: try TranscriptProjectionStore(fileURL: nil)
            )
        )
        try feeds.ensureFeed(conversationStreamID: "dormant")
        conversation.yield(TranscriptProjectionEventDTO(
            conversationStreamID: "dormant",
            sequence: 1,
            eventID: "archive-1",
            runID: nil,
            kind: .conversationArchived,
            payload: .string("")
        ))
        try await feeds.waitUntilApplied(
            conversationStreamID: "dormant",
            sequence: 1
        )

        try feeds.ensureFeed(
            conversationStreamID: "dormant",
            temporaryThroughSequence: 1
        )

        XCTAssertTrue(feeds.observedConversationIDs.isEmpty)
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
    private(set) var finishedRunIDs: [String] = []
    var prepareError: Error?

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
        if let prepareError {
            throw prepareError
        }
    }

    func finishModelRun(runID: String) async {
        finishedRunIDs.append(runID)
    }
}

private final class RecordingTranscriptClient:
    ConversationBridgeClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var feedCount = 0
    private var continuations: [
        String: AsyncThrowingStream<
            TranscriptProjectionEventDTO,
            Error
        >.Continuation
    ] = [:]
    private(set) var submittedCommand: TranscriptCommandDTO?
    private(set) var feedWasInstalledBeforeSubmit = false
    var submitError: Error?
    var sessions: [ConversationSummaryDTO] = []
    private(set) var cancelledFeedCount = 0

    func submitTranscriptCommand(
        _ command: TranscriptCommandDTO
    ) async throws -> TranscriptCommandResultDTO {
        if let submitError {
            throw submitError
        }
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
        conversationStreamID: String,
        afterSequence _: UInt64
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error> {
        lock.withLock {
            feedCount += 1
        }
        return AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[conversationStreamID] = continuation
            }
        }
    }

    func cancelTranscriptProjectionSubscription(
        subscriptionID _: String
    ) async {
        lock.withLock {
            feedCount -= 1
            cancelledFeedCount += 1
        }
    }

    func yield(_ event: TranscriptProjectionEventDTO) {
        lock.withLock {
            continuations[event.conversationStreamID]
        }?.yield(event)
    }

    func listSessions() async throws -> [ConversationSummaryDTO] { sessions }

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
