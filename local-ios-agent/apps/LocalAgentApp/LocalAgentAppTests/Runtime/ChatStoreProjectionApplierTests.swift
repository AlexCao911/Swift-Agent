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
