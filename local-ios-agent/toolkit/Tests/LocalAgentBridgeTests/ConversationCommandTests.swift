import Foundation
import LocalAgentLLMContracts
import Testing
@testable import LocalAgentBridge

@Suite("Conversation command bridge")
struct ConversationCommandTests {
    @Test
    func taggedCommandsUseExactSnakeCasePayloads() throws {
        let command = TranscriptCommandDTO.send(
            requestID: "request-1",
            conversationStreamID: "conversation-1",
            clientMessageID: "message-1",
            text: "hello",
            attachments: [],
            runStartSnapshot: try snapshot()
        )

        let data = try JSONEncoder().encode(command)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["kind"] as? String == "send")
        #expect(object["request_id"] as? String == "request-1")
        #expect(object["conversation_stream_id"] as? String == "conversation-1")
        #expect(object["client_message_id"] as? String == "message-1")
        #expect(object["run_start_snapshot"] != nil)
        #expect(
            try JSONDecoder().decode(TranscriptCommandDTO.self, from: data)
                == command
        )
    }

    @Test
    func conversationClientRoutesCommandWithoutReturningProjectionEvents() async throws {
        let gateway = RecordingTranscriptGateway()
        let client = RustConversationBridgeClient(
            gateway: gateway,
            legacyClient: EmptyConversationRuntimeClient()
        )

        let result = try await client.submitTranscriptCommand(
            .archiveConversation(
                requestID: "archive-1",
                conversationStreamID: "conversation-1"
            )
        )

        #expect(result.acceptedSequence == 7)
        #expect(gateway.lastOperation == .transcriptCommand)
    }

    @Test
    func projectionCursorAndIdentityDecodeWithoutRunID() throws {
        let data = Data(
            """
            {
              "conversation_stream_id": "conversation-1",
              "sequence": 9,
              "event_id": "event-9",
              "run_id": null,
              "kind": "conversation_archived",
              "payload": {"command": "archive"}
            }
            """.utf8
        )

        let event = try JSONDecoder().decode(
            TranscriptProjectionEventDTO.self,
            from: data
        )
        #expect(event.sequence == 9)
        #expect(event.runID == nil)
        #expect(event.kind == .conversationArchived)
    }

    private func snapshot() throws -> RunStartSnapshotDTO {
        try RunStartSnapshotDTO.make(
            orderedPromptDocuments: [],
            skillDescriptors: [],
            orderedToolDefinitions: []
        )
    }
}

private final class RecordingTranscriptGateway:
    RustAgentOSBridgeGateway,
    @unchecked Sendable
{
    var lastOperation: RustAgentOSOperation?

    func request<Request: Encodable, Response: Decodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request,
        as response: Response.Type
    ) async throws -> Response {
        lastOperation = operation
        let data = try JSONEncoder().encode(
            TranscriptCommandResultDTO(
                conversationStreamID: "conversation-1",
                acceptedSequence: 7,
                runID: nil
            )
        )
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func stream<Request: Encodable>(
        _ operation: RustAgentOSOperation,
        _ request: Request
    ) -> AsyncThrowingStream<RuntimeEventDTO, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct EmptyConversationRuntimeClient: ConversationRuntimeClient {
    func conversationSummaries() async throws -> [ConversationSummaryDTO] { [] }
    func activeBranch(
        sessionId: String,
        leafId: String?
    ) async throws -> [RuntimeEventDTO] { [] }
    func forkSession(sessionId: String, leafId: String) async throws -> String {
        "unused"
    }
    func archiveSession(sessionId: String) async throws {}
    func renameSession(sessionId: String, title: String) async throws {}
    func deleteSession(sessionId: String) async throws {}
}
