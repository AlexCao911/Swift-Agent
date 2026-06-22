import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Runtime stream buffer")
struct RuntimeStreamBufferTests {
    @Test("text deltas are coalesced by message id")
    func coalescesDeltasByMessageId() {
        var buffer = RuntimeStreamBuffer()

        #expect(buffer.append(delta("a", messageId: "assistant_1", text: "Hel")).isEmpty)
        #expect(buffer.append(delta("b", messageId: "assistant_1", text: "lo")).isEmpty)

        let flushed = buffer.flush()
        #expect(flushed.count == 1)
        #expect(flushed[0].payload == #"{"message_id":"assistant_1","text":"Hello"}"#)
    }

    @Test("terminal event flushes buffered delta before terminal")
    func terminalEventFlushesBufferedDelta() {
        var buffer = RuntimeStreamBuffer()

        _ = buffer.append(delta("a", messageId: "assistant_1", text: "partial"))
        let events = buffer.append(event(id: "failed", kind: .runFailed, payload: #"{"message":"failed"}"#))

        #expect(events.map(\.kind) == [.assistantTextDelta, .runFailed])
    }

    @Test("passthrough event flushes buffered delta first")
    func passthroughEventFlushesBufferedDeltaFirst() {
        var buffer = RuntimeStreamBuffer()

        _ = buffer.append(delta("a", messageId: "assistant_1", text: "partial"))
        let events = buffer.append(event(id: "raw", kind: .assistantTextDelta, payload: " raw"))

        #expect(events.map(\.payload) == [
            #"{"message_id":"assistant_1","text":"partial"}"#,
            " raw",
        ])
    }

    @Test("coalesced payload remains valid JSON for escaped text")
    func coalescedPayloadEscapesText() throws {
        var buffer = RuntimeStreamBuffer()

        _ = buffer.append(delta("a", messageId: "assistant_1", text: "quote \""))
        _ = buffer.append(delta("b", messageId: "assistant_1", text: "\nnext"))

        let payload = try #require(buffer.flush().first?.payload)
        let object = try #require(jsonObject(from: payload))
        #expect(object["message_id"] == "assistant_1")
        #expect(object["text"] == "quote \"\nnext")
    }

    private func delta(_ id: String, messageId: String, text: String) -> RuntimeEventDTO {
        event(
            id: id,
            kind: .assistantTextDelta,
            payload: encodedPayload(["message_id": messageId, "text": text])
        )
    }

    private func event(id: String, kind: RuntimeEventKindDTO, payload: String) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }

    private func encodedPayload(_ object: [String: String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(from payload: String) -> [String: String]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return nil
        }
        return object
    }
}
