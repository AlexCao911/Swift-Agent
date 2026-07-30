import LocalAgentBridge
import LocalAgentLLMContracts
import XCTest
@testable import LocalAgentApp

@MainActor
final class ChatStoreProjectionApplierTests: XCTestCase {
    func testAppliesOnlyContiguousEventsAndReplaysAfterRelaunch() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "projection-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let firstStore = ChatStore()
        let persistence = try TranscriptProjectionStore(fileURL: fileURL)
        let first = ChatStoreProjectionApplier(
            store: firstStore,
            persistence: persistence
        )

        XCTAssertEqual(
            try first.apply(userEvent(sequence: 1, text: "hello")),
            .applied
        )
        XCTAssertEqual(
            try first.apply(userEvent(sequence: 1, text: "hello")),
            .duplicate
        )
        XCTAssertEqual(
            try first.apply(assistantEvent(sequence: 3, text: "too early")),
            .gap(expected: 2, received: 3)
        )
        XCTAssertEqual(try first.cursor(for: "conversation-1"), 1)
        XCTAssertEqual(
            firstStore.projectedMessages(
                conversationStreamID: "conversation-1"
            ).map(\.text),
            ["hello"]
        )

        XCTAssertEqual(
            try first.apply(assistantEvent(sequence: 2, text: "done")),
            .applied
        )
        let relaunchedStore = ChatStore()
        let relaunched = ChatStoreProjectionApplier(
            store: relaunchedStore,
            persistence: try TranscriptProjectionStore(fileURL: fileURL)
        )
        try relaunched.replay(conversationStreamID: "conversation-1")

        XCTAssertEqual(try relaunched.cursor(for: "conversation-1"), 2)
        XCTAssertEqual(
            relaunchedStore.projectedMessages(
                conversationStreamID: "conversation-1"
            ).map(\.text),
            ["hello", "done"]
        )
    }

    func testTranscriptMutationsProjectTheSameEffectiveHistoryAsRust() throws {
        let retryStore = ChatStore()
        let retry = ChatStoreProjectionApplier(
            store: retryStore,
            persistence: try TranscriptProjectionStore(fileURL: nil)
        )
        try applyConversationPrefix(to: retry)
        XCTAssertEqual(
            try retry.apply(commandEvent(
                sequence: 5,
                eventID: "retry",
                kind: .transcriptRetryRequested,
                fields: ["anchor_event_id": "event-1"]
            )),
            .applied
        )
        XCTAssertEqual(
            retryStore.projectedMessages(
                conversationStreamID: "conversation-1"
            ).map(\.text),
            ["first"]
        )

        let anchorStore = ChatStore()
        let anchorApplier = ChatStoreProjectionApplier(
            store: anchorStore,
            persistence: try TranscriptProjectionStore(fileURL: nil)
        )
        try applyConversationPrefix(to: anchorApplier)
        XCTAssertEqual(
            anchorStore.retryAnchorEventID(
                forAssistantMessageID: "event-4",
                conversationStreamID: "conversation-1"
            ),
            "event-3"
        )

        let editStore = ChatStore()
        let edit = ChatStoreProjectionApplier(
            store: editStore,
            persistence: try TranscriptProjectionStore(fileURL: nil)
        )
        try applyConversationPrefix(to: edit)
        XCTAssertEqual(
            try edit.apply(commandEvent(
                sequence: 5,
                eventID: "edit",
                kind: .messageEdited,
                fields: [
                    "target_event_id": "event-3",
                    "replacement_text": "replacement",
                ]
            )),
            .applied
        )
        XCTAssertEqual(
            editStore.projectedMessages(
                conversationStreamID: "conversation-1"
            ).map(\.text),
            ["first", "first answer", "replacement"]
        )

        let deleteStore = ChatStore()
        let delete = ChatStoreProjectionApplier(
            store: deleteStore,
            persistence: try TranscriptProjectionStore(fileURL: nil)
        )
        try applyConversationPrefix(to: delete)
        XCTAssertEqual(
            try delete.apply(commandEvent(
                sequence: 5,
                eventID: "delete",
                kind: .messageDeleted,
                fields: ["target_event_id": "event-3"]
            )),
            .applied
        )
        XCTAssertEqual(
            deleteStore.projectedMessages(
                conversationStreamID: "conversation-1"
            ).map(\.text),
            ["first", "first answer"]
        )
    }
}

@MainActor
private func applyConversationPrefix(
    to applier: ChatStoreProjectionApplier
) throws {
    _ = try applier.apply(userEvent(sequence: 1, text: "first"))
    _ = try applier.apply(assistantEvent(sequence: 2, text: "first answer"))
    _ = try applier.apply(userEvent(sequence: 3, text: "second"))
    _ = try applier.apply(assistantEvent(sequence: 4, text: "second answer"))
}

private func commandEvent(
    sequence: UInt64,
    eventID: String,
    kind: TranscriptProjectionKindDTO,
    fields: [String: String]
) throws -> TranscriptProjectionEventDTO {
    TranscriptProjectionEventDTO(
        conversationStreamID: "conversation-1",
        sequence: sequence,
        eventID: eventID,
        runID: nil,
        kind: kind,
        payload: try .object(entries: [
            .init(
                name: "command",
                value: try .object(entries: fields.sorted { $0.key < $1.key }.map {
                    .init(name: $0.key, value: .string($0.value))
                })
            ),
        ])
    )
}

private func userEvent(
    sequence: UInt64,
    text: String
) throws -> TranscriptProjectionEventDTO {
    TranscriptProjectionEventDTO(
        conversationStreamID: "conversation-1",
        sequence: sequence,
        eventID: "event-\(sequence)",
        runID: "run-1",
        kind: .userMessage,
        payload: try .object(entries: [
            .init(
                name: "command",
                value: try .object(entries: [
                    .init(name: "text", value: .string(text)),
                ])
            ),
        ])
    )
}

private func assistantEvent(
    sequence: UInt64,
    text: String
) -> TranscriptProjectionEventDTO {
    TranscriptProjectionEventDTO(
        conversationStreamID: "conversation-1",
        sequence: sequence,
        eventID: "event-\(sequence)",
        runID: "run-1",
        kind: .assistantMessageCompleted,
        payload: .string(text)
    )
}
