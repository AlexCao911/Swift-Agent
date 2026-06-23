import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Rust runtime client streaming")
struct RustRuntimeClientStreamingTests {
    @Test
    func sendMessageStreamYieldsEventBeforeFinalResultCompletes() async throws {
        let probe = StreamingRuntimeCFunctionProbe()
        let client = try RustRuntimeClient(functions: probe.table())

        let stream = client.sendMessageStream(
            sessionId: "session_1",
            parentEventId: nil,
            text: "hello"
        )
        var iterator = stream.events.makeAsyncIterator()

        let firstEvent = try await iterator.next()

        #expect(firstEvent?.kind == .assistantTextDelta)
        #expect(firstEvent?.payload == "hello")
        #expect(!probe.didReturnFinalResult)

        probe.allowFinalResult()
        let result = try await stream.result.value

        #expect(result.state == .completed)
        #expect(probe.sentMessageJson?.contains(#""text":"hello""#) == true)
    }
}

private final class StreamingRuntimeCFunctionProbe: @unchecked Sendable {
    private let handle = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private let finalResultGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var returnedFinalResult = false

    var sentMessageJson: String?

    var didReturnFinalResult: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returnedFinalResult
    }

    func allowFinalResult() {
        finalResultGate.signal()
    }

    func table() -> RustRuntimeCFunctionTable {
        RustRuntimeCFunctionTable(
            makeRuntime: { self.handle },
            freeRuntime: { _ in },
            freeString: { value in value?.deallocate() },
            createSession: { _ in Self.makeCString(#""session_1""#) },
            sessionIds: { _ in Self.makeCString(#"["session_1"]"#) },
            conversationSummaries: { _ in Self.makeCString("[]") },
            forkSession: { _, _, _ in Self.makeCString(#""session_forked""#) },
            activeBranch: { _, _, _ in Self.makeCString("[]") },
            archiveSession: { _, _ in Self.makeCString("null") },
            deleteSession: { _, _ in Self.makeCString("null") },
            registerToolSchema: { _, _ in Self.makeCString("null") },
            setPermissionState: { _, _ in Self.makeCString("null") },
            sendMessage: { _, _ in Self.makeCString(Self.turnJson(state: "completed")) },
            sendMessageStreaming: sendMessageStreaming,
            pendingToolRequests: { _ in Self.makeCString("[]") },
            pendingApprovalRequests: { _ in Self.makeCString("[]") },
            submitToolResult: { _, _, _ in Self.makeCString(Self.turnJson(state: "completed")) },
            submitToolResultStreaming: { _, _, _, _, _ in Self.makeCString(Self.turnJson(state: "completed")) },
            submitApprovalResponse: { _, _ in Self.makeCString(Self.turnJson(state: "completed")) },
            cancel: { _, _ in
                Self.makeCString("""
                {
                  "id": "entry_cancelled",
                  "session_id": "session_1",
                  "parent_id": null,
                  "run_id": "run_1",
                  "sequence": 0,
                  "depth": 0,
                  "kind": "run_cancelled",
                  "payload": "cancelled",
                  "blob_refs": []
                }
                """)
            },
            latestPromptDebugSnapshot: { _ in Self.makeCString("null") },
            providerProfiles: { _ in Self.makeCString("[]") },
            activeProvider: { _ in
                Self.makeCString("""
                {
                  "id": "mock",
                  "display_name": "Mock",
                  "kind": "mock",
                  "max_context_tokens": 100
                }
                """)
            },
            setProvider: { _, _ in
                Self.makeCString("""
                {
                  "id": "entry_provider",
                  "session_id": "session_1",
                  "parent_id": null,
                  "run_id": null,
                  "sequence": 0,
                  "depth": 0,
                  "kind": "provider_changed",
                  "payload": "{}",
                  "blob_refs": []
                }
                """)
            }
        )
    }

    private func sendMessageStreaming(
        _ runtime: UnsafeMutableRawPointer?,
        _ inputJson: UnsafePointer<CChar>?,
        _ callback: RustRuntimeCFunctionTable.RuntimeEventCallback?,
        _ userData: UnsafeMutableRawPointer?
    ) -> UnsafeMutablePointer<CChar>? {
        sentMessageJson = String(cString: inputJson!)
        let eventJson = """
        {
          "id": "entry_delta",
          "session_id": "session_1",
          "parent_id": "entry_start",
          "run_id": "run_1",
          "sequence": 2,
          "depth": 2,
          "kind": "assistant_text_delta",
          "payload": "hello",
          "blob_refs": []
        }
        """
        eventJson.withCString { pointer in
            _ = callback?(pointer, userData)
        }
        _ = finalResultGate.wait(timeout: .now() + 2)
        lock.lock()
        returnedFinalResult = true
        lock.unlock()
        return Self.makeCString(Self.turnJson(state: "completed"))
    }

    private static func makeCString(_ string: String) -> UnsafeMutablePointer<CChar> {
        let cString = string.utf8CString
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: cString.count)
        cString.withUnsafeBufferPointer { buffer in
            pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
        }
        return pointer
    }

    private static func turnJson(state: String) -> String {
        """
        {
          "run_id": "run_1",
          "state": "\(state)",
          "events": [],
          "pending_tool_call_id": null
        }
        """
    }
}
