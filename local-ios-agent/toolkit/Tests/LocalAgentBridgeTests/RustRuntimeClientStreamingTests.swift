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
        #expect(firstEvent?.payload == "hello 0")
        #expect(!probe.didReturnFinalResult)

        probe.allowFinalResult()
        let result = try await stream.result.value

        #expect(result.state == .completed)
        #expect(probe.sentMessageJson?.contains(#""text":"hello""#) == true)
    }

    @Test
    func streamBufferOverflowFinishesWithBridgeError() async throws {
        let probe = StreamingRuntimeCFunctionProbe()
        probe.eventsToEmit = runtimeEventStreamBufferLimit + 2
        let client = try RustRuntimeClient(functions: probe.table())

        let stream = client.sendMessageStream(
            sessionId: "session_1",
            parentEventId: nil,
            text: "overflow"
        )

        do {
            _ = try await stream.result.value
            Issue.record("Expected stream result to throw after callback returned non-zero")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "ffi")
            #expect(error.message.contains("stream event callback returned non-zero"))
        }

        #expect(probe.callbackReturnValues.contains { $0 != 0 })
    }

    @Test
    func streamTerminationMakesLaterCallbacksReturnNonZero() async throws {
        let probe = StreamingRuntimeCFunctionProbe()
        probe.waitBeforeSecondEvent = true
        probe.eventsToEmit = 2
        let client = try RustRuntimeClient(functions: probe.table())

        let stream = client.sendMessageStream(
            sessionId: "session_1",
            parentEventId: nil,
            text: "cancel"
        )

        let consumer = Task<[RuntimeEventDTO], Error> {
            var observed: [RuntimeEventDTO] = []
            for try await event in stream.events {
                observed.append(event)
            }
            return observed
        }

        while probe.callbackReturnValues.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        consumer.cancel()
        probe.allowSecondEvent()

        do {
            _ = try await stream.result.value
            Issue.record("Expected result to throw after terminated callback returned non-zero")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "ffi")
        }

        #expect(probe.callbackReturnValues.last == 1)
        do {
            _ = try await consumer.value
            Issue.record("Expected consumer task to be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

private final class StreamingRuntimeCFunctionProbe: @unchecked Sendable {
    private let handle = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private let finalResultGate = DispatchSemaphore(value: 0)
    private let secondEventGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var returnedFinalResult = false
    private var callbackStatuses: [CInt] = []

    var sentMessageJson: String?
    var eventsToEmit = 1
    var waitBeforeSecondEvent = false

    var didReturnFinalResult: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returnedFinalResult
    }

    var callbackReturnValues: [CInt] {
        lock.lock()
        defer { lock.unlock() }
        return callbackStatuses
    }

    func allowFinalResult() {
        finalResultGate.signal()
    }

    func allowSecondEvent() {
        secondEventGate.signal()
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
            renameSession: { _, _, _ in Self.makeCString("null") },
            updateRuntimeOptions: { _, _ in Self.makeCString("null") },
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
            },
            startRun: { _, _ in Self.makeCString(#"{"run_id":"run_1"}"#) },
            loadDebugArchive: { _, _ in
                Self.makeCString("""
                {
                  "run_id": "run_1",
                  "state": "completed",
                  "events": [],
                  "checkpoints": []
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
        for index in 0..<eventsToEmit {
            if waitBeforeSecondEvent && index == 1 {
                _ = secondEventGate.wait(timeout: .now() + 2)
            }
            let eventJson = Self.eventJson(
                id: "entry_delta_\(index)",
                sequence: index + 2,
                payload: "hello \(index)"
            )
            let status = eventJson.withCString { pointer in
                callback?(pointer, userData) ?? 0
            }
            lock.lock()
            callbackStatuses.append(status)
            lock.unlock()
            if status != 0 {
                return Self.makeCString(#"{"error":{"kind":"ffi","message":"stream event callback returned non-zero"}}"#)
            }
        }
        _ = finalResultGate.wait(timeout: .now() + 2)
        lock.lock()
        returnedFinalResult = true
        lock.unlock()
        return Self.makeCString(Self.turnJson(state: "completed"))
    }

    private static func eventJson(id: String, sequence: Int, payload: String) -> String {
        """
        {
          "id": "\(id)",
          "session_id": "session_1",
          "parent_id": "entry_start",
          "run_id": "run_1",
          "sequence": \(sequence),
          "depth": 2,
          "kind": "assistant_text_delta",
          "payload": "\(payload)",
          "blob_refs": []
        }
        """
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
