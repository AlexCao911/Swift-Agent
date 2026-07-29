import Foundation
import LocalAgentBridge
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentApp

@Suite("Projection relaunch product path")
struct RelaunchProjectionReplayProductTests {
    @Test("relaunch replays the cursor, repairs a gap, and releases subscriptions")
    @MainActor
    func relaunchReplayRepairsGapAndStopsIdleFeed() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "projection-product-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let client = ProjectionReplayClient()
        let firstStore = ChatStore()
        let firstController = ProjectionFeedController(
            client: client,
            applier: ChatStoreProjectionApplier(
                store: firstStore,
                persistence: try TranscriptProjectionStore(fileURL: fileURL)
            )
        )

        try firstController.ensureFeed(
            conversationStreamID: "replay-conversation",
            persistent: true
        )
        try await client.emit(projectionEvent(sequence: 1, text: "hello"))
        try await client.emit(projectionEvent(sequence: 2, text: "first answer"))
        try await firstController.waitUntilApplied(
            conversationStreamID: "replay-conversation",
            sequence: 2
        )
        await firstController.stopAll()

        let relaunchedStore = ChatStore()
        let relaunchedApplier = ChatStoreProjectionApplier(
            store: relaunchedStore,
            persistence: try TranscriptProjectionStore(fileURL: fileURL)
        )
        try relaunchedApplier.replay(
            conversationStreamID: "replay-conversation"
        )
        #expect(
            relaunchedStore.projectedMessages(
                conversationStreamID: "replay-conversation"
            ).map(\.text) == ["hello", "first answer"]
        )

        let relaunchedController = ProjectionFeedController(
            client: client,
            applier: relaunchedApplier
        )
        try relaunchedController.ensureFeed(
            conversationStreamID: "replay-conversation",
            persistent: true
        )
        try await client.emit(projectionEvent(sequence: 4, text: "gap"))
        try await waitUntil {
            client.observedAfterSequences == [0, 2, 2]
        }
        try await client.emit(projectionEvent(sequence: 3, text: "replayed"))
        try await client.emit(projectionEvent(sequence: 4, text: "live"))
        try await relaunchedController.waitUntilApplied(
            conversationStreamID: "replay-conversation",
            sequence: 4
        )

        #expect(
            relaunchedStore.projectedMessages(
                conversationStreamID: "replay-conversation"
            ).map(\.text) == ["hello", "first answer", "replayed", "live"]
        )
        await relaunchedController.stopAll()
        #expect(client.activeSubscriptionCount == 0)
        #expect(client.cancelledSubscriptionCount == 3)
    }
}

private final class ProjectionReplayClient:
    ConversationBridgeClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuations: [
        String: AsyncThrowingStream<TranscriptProjectionEventDTO, Error>.Continuation
    ] = [:]
    private var subscriptionOrder: [String] = []
    private var afterSequences: [UInt64] = []
    private var cancellationCount = 0

    var observedAfterSequences: [UInt64] {
        lock.withLock { afterSequences }
    }

    var activeSubscriptionCount: Int {
        lock.withLock { continuations.count }
    }

    var cancelledSubscriptionCount: Int {
        lock.withLock { cancellationCount }
    }

    func emit(_ event: TranscriptProjectionEventDTO) async throws {
        let continuation = try lock.withLock {
            guard let subscriptionID = subscriptionOrder.last,
                  let continuation = continuations[subscriptionID] else {
                throw ProjectionReplayFailure()
            }
            return continuation
        }
        continuation.yield(event)
    }

    func observeTranscriptProjections(
        subscriptionID: String,
        conversationStreamID _: String,
        afterSequence: UInt64
    ) -> AsyncThrowingStream<TranscriptProjectionEventDTO, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[subscriptionID] = continuation
                subscriptionOrder.append(subscriptionID)
                afterSequences.append(afterSequence)
            }
        }
    }

    func cancelTranscriptProjectionSubscription(
        subscriptionID: String
    ) async {
        let continuation = lock.withLock {
            cancellationCount += 1
            return continuations.removeValue(forKey: subscriptionID)
        }
        continuation?.finish()
    }

    func submitTranscriptCommand(
        _: TranscriptCommandDTO
    ) async throws -> TranscriptCommandResultDTO {
        throw ProjectionReplayFailure()
    }

    func listSessions() async throws -> [ConversationSummaryDTO] { [] }
    func prepareUserTurn(
        _: PrepareUserTurnRequestDTO
    ) async throws -> PreparedUserTurnDTO {
        throw ProjectionReplayFailure()
    }
    func activeBranch(
        sessionId _: String,
        leafId _: String?
    ) async throws -> [RuntimeEventDTO] { [] }
    func forkSession(
        sessionId _: String,
        leafId _: String
    ) async throws -> String {
        throw ProjectionReplayFailure()
    }
    func archiveSession(sessionId _: String) async throws {}
    func renameSession(sessionId _: String, title _: String) async throws {}
    func deleteSession(sessionId _: String) async throws {}
    func commitAssistantResult(
        _: CommitAssistantResultRequestDTO
    ) async throws -> ConversationCommitResultDTO {
        throw ProjectionReplayFailure()
    }
}

private struct ProjectionReplayFailure: Error {}

private func projectionEvent(
    sequence: UInt64,
    text: String
) throws -> TranscriptProjectionEventDTO {
    TranscriptProjectionEventDTO(
        conversationStreamID: "replay-conversation",
        sequence: sequence,
        eventID: "event-\(sequence)",
        runID: "run-1",
        kind: sequence == 1 ? .userMessage : .assistantMessageCompleted,
        payload: sequence == 1
            ? try .object(entries: [
                .init(
                    name: "command",
                    value: try .object(entries: [
                        .init(name: "text", value: .string(text)),
                    ])
                ),
            ])
            : .string(text)
    )
}

private func waitUntil(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ProjectionReplayFailure()
}
