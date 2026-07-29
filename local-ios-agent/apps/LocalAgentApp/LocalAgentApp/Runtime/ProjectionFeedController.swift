import Foundation
import LocalAgentBridge

@MainActor
final class ProjectionFeedController {
    private struct Feed {
        let subscriptionID: String
        let task: Task<Void, Never>
        var persistent: Bool
        var temporaryThroughSequence: UInt64?
    }

    private let client: any ConversationBridgeClient
    private let applier: ChatStoreProjectionApplier
    private var feeds: [String: Feed] = [:]

    init(
        client: any ConversationBridgeClient,
        applier: ChatStoreProjectionApplier
    ) {
        self.client = client
        self.applier = applier
    }

    var observedConversationIDs: Set<String> {
        Set(feeds.keys)
    }

    func reconcilePersistentFeeds(
        runningConversationIDs: Set<String>,
        currentConversationID: String?
    ) async {
        var desired = runningConversationIDs
        if let currentConversationID {
            desired.insert(currentConversationID)
        }

        for streamID in desired {
            try? ensureFeed(
                conversationStreamID: streamID,
                persistent: true
            )
        }
        for streamID in Set(feeds.keys).subtracting(desired) {
            guard feeds[streamID]?.temporaryThroughSequence == nil else {
                feeds[streamID]?.persistent = false
                continue
            }
            await stopFeed(conversationStreamID: streamID)
        }
    }

    func ensureFeed(
        conversationStreamID: String,
        persistent: Bool = false,
        temporaryThroughSequence: UInt64? = nil
    ) throws {
        guard !conversationStreamID.isEmpty else {
            throw TranscriptProjectionStoreError(
                message: "conversation stream ID is empty"
            )
        }
        if var feed = feeds[conversationStreamID] {
            feed.persistent = feed.persistent || persistent
            if let temporaryThroughSequence {
                feed.temporaryThroughSequence = max(
                    feed.temporaryThroughSequence ?? 0,
                    temporaryThroughSequence
                )
            }
            feeds[conversationStreamID] = feed
            return
        }
        try startFeed(
            conversationStreamID: conversationStreamID,
            persistent: persistent,
            temporaryThroughSequence: temporaryThroughSequence
        )
    }

    func waitUntilApplied(
        conversationStreamID: String,
        sequence: UInt64
    ) async throws {
        while try applier.cursor(for: conversationStreamID) < sequence {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stopAll() async {
        for streamID in Array(feeds.keys) {
            await stopFeed(conversationStreamID: streamID)
        }
    }

    private func startFeed(
        conversationStreamID: String,
        persistent: Bool,
        temporaryThroughSequence: UInt64?
    ) throws {
        let cursor = try applier.cursor(for: conversationStreamID)
        let subscriptionID = "projection-\(UUID().uuidString.lowercased())"
        let stream = client.observeTranscriptProjections(
            subscriptionID: subscriptionID,
            conversationStreamID: conversationStreamID,
            afterSequence: cursor
        )
        let task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self else { return }
                    let result = try self.applier.apply(event)
                    switch result {
                    case .applied, .duplicate:
                        await self.closeTemporaryFeedIfSatisfied(
                            conversationStreamID: conversationStreamID,
                            appliedSequence: event.sequence
                        )
                    case .gap:
                        await self.restartFeedAfterGap(
                            conversationStreamID: conversationStreamID
                        )
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.feeds[conversationStreamID] != nil else {
                    return
                }
                await self.restartFeedAfterGap(
                    conversationStreamID: conversationStreamID
                )
            }
        }
        feeds[conversationStreamID] = Feed(
            subscriptionID: subscriptionID,
            task: task,
            persistent: persistent,
            temporaryThroughSequence: temporaryThroughSequence
        )
    }

    private func restartFeedAfterGap(
        conversationStreamID: String
    ) async {
        guard let previous = feeds.removeValue(forKey: conversationStreamID)
        else { return }
        previous.task.cancel()
        await client.cancelTranscriptProjectionSubscription(
            subscriptionID: previous.subscriptionID
        )
        try? startFeed(
            conversationStreamID: conversationStreamID,
            persistent: previous.persistent,
            temporaryThroughSequence: previous.temporaryThroughSequence
        )
    }

    private func closeTemporaryFeedIfSatisfied(
        conversationStreamID: String,
        appliedSequence: UInt64
    ) async {
        guard let feed = feeds[conversationStreamID],
              !feed.persistent,
              let target = feed.temporaryThroughSequence,
              appliedSequence >= target
        else { return }
        await stopFeed(conversationStreamID: conversationStreamID)
    }

    private func stopFeed(conversationStreamID: String) async {
        guard let feed = feeds.removeValue(forKey: conversationStreamID)
        else { return }
        feed.task.cancel()
        await client.cancelTranscriptProjectionSubscription(
            subscriptionID: feed.subscriptionID
        )
    }
}
