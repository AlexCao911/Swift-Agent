import Foundation
import Testing
@testable import LocalAgentBridge

@Suite("Runtime clients")
struct RustRuntimeClientContractTests {
    @Test
    func mockRuntimeClientRecordsCallsAndReturnsDeterministicValues() async throws {
        let turn = AgentTurnResultDTO(
            runId: "run_mock",
            state: .completed,
            events: [],
            pendingToolCallId: nil
        )
        let mock = MockRuntimeClient(
            sessionIds: ["session_existing"],
            turnResult: turn,
            promptDebugSnapshot: PromptDebugSnapshotDTO(renderedText: "debug")
        )

        let created = try await mock.createSession()
        let ids = try await mock.sessionIds()
        let sent = try await mock.sendMessage(
            sessionId: created,
            parentEventId: nil,
            text: "hello"
        )
        let snapshot = try await mock.latestPromptDebugSnapshot()
        let messages = await mock.sentMessages

        #expect(created == "session_2")
        #expect(ids == ["session_existing", "session_2"])
        #expect(sent == turn)
        #expect(snapshot?.renderedText == "debug")
        #expect(messages == [
            MockRuntimeClient.SentMessage(
                sessionId: "session_2",
                parentEventId: nil,
                text: "hello"
            )
        ])
    }

    @Test
    func rustRuntimeClientDecodesResponsesEncodesRequestsAndFreesStrings() async throws {
        let probe = RuntimeCFunctionProbe()
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        #expect(try await client?.createSession() == "session_1")
        #expect(try await client?.sessionIds() == ["session_1"])

        try await client?.registerToolSchema(ToolSchemaDTO(
            name: "debug.echo",
            description: "Echo",
            parametersJsonSchema: #"{"type":"object"}"#,
            riskLevel: .confirm
        ))
        let turn = try await client?.sendMessage(
            sessionId: "session_1",
            parentEventId: "entry_parent",
            text: "use tool"
        )
        let pendingTools = try await client?.pendingToolRequests()
        let pendingApprovals = try await client?.pendingApprovalRequests()
        let submittedTool = try await client?.submitToolResult(
            runId: "run_3",
            result: ToolResultDTO(
                displayText: "display",
                modelText: "model",
                structuredJson: "{}",
                auditText: "audit",
                sensitivity: .public,
                retention: .runOnly,
                isError: false
            )
        )
        let submittedApproval = try await client?.submitApprovalResponse(
            ApprovalProtocolResponseDTO(
                approvalId: "approval_1",
                approved: true,
                reason: nil
            )
        )
        let cancelled = try await client?.cancel(runId: "run_3")
        let snapshot = try await client?.latestPromptDebugSnapshot()

        #expect(turn?.state == .waitingTool)
        #expect(pendingTools?.first?.runId == "run_3")
        #expect(pendingApprovals?.first?.approvalId == "approval_1")
        #expect(submittedTool?.state == .completed)
        #expect(submittedApproval?.runId == "run_3")
        #expect(cancelled?.kind == .runCancelled)
        #expect(snapshot?.renderedText == "system\npolicy")

        let registeredSchema = try decodedObject(try #require(probe.registeredSchemaJson))
        let sentMessage = try decodedObject(try #require(probe.sentMessageJson))
        let submittedResult = try decodedObject(try #require(probe.submittedToolResultJson))
        let approvalResponse = try decodedObject(try #require(probe.submittedApprovalResponseJson))

        #expect(registeredSchema["risk_level"] as? String == "confirm")
        #expect(sentMessage["parent_event_id"] as? String == "entry_parent")
        #expect(sentMessage["text"] as? String == "use tool")
        #expect(submittedResult["retention"] as? String == "run_only")
        #expect(approvalResponse["reason"] is NSNull)

        client = nil

        #expect(probe.freedRuntimeHandles == 1)
        #expect(probe.freedStrings == 10)
    }

    @Test
    func rustRuntimeClientThrowsBridgeErrorsAndStillFreesReturnedStrings() async throws {
        let probe = RuntimeCFunctionProbe()
        probe.createSessionResponse = #"{"error":{"kind":"ffi","message":"bad input"}}"#
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        do {
            _ = try await client?.createSession()
            Issue.record("Expected createSession to throw")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "ffi")
            #expect(error.message == "bad input")
        }

        client = nil

        #expect(probe.freedStrings == 1)
        #expect(probe.freedRuntimeHandles == 1)
    }
}

private final class RuntimeCFunctionProbe: @unchecked Sendable {
    var createSessionResponse = #""session_1""#
    var freedStrings = 0
    var freedRuntimeHandles = 0
    var registeredSchemaJson: String?
    var sentMessageJson: String?
    var submittedToolResultJson: String?
    var submittedApprovalResponseJson: String?

    private let handle = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    func table() -> RustRuntimeCFunctionTable {
        RustRuntimeCFunctionTable(
            makeRuntime: makeRuntime,
            freeRuntime: freeRuntime,
            freeString: freeString,
            createSession: createSession,
            sessionIds: sessionIds,
            registerToolSchema: registerToolSchema,
            sendMessage: sendMessage,
            pendingToolRequests: pendingToolRequests,
            pendingApprovalRequests: pendingApprovalRequests,
            submitToolResult: submitToolResult,
            submitApprovalResponse: submitApprovalResponse,
            cancel: cancel,
            latestPromptDebugSnapshot: latestPromptDebugSnapshot
        )
    }

    func makeRuntime() -> UnsafeMutableRawPointer? {
        handle
    }

    func freeRuntime(_ runtime: UnsafeMutableRawPointer?) {
        if runtime != nil {
            freedRuntimeHandles += 1
        }
    }

    func freeString(_ value: UnsafeMutablePointer<CChar>?) {
        value?.deallocate()
        freedStrings += 1
    }

    func createSession(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString(createSessionResponse)
    }

    func sessionIds(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString(#"["session_1"]"#)
    }

    func registerToolSchema(
        _ runtime: UnsafeMutableRawPointer?,
        _ schemaJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        registeredSchemaJson = String(cString: schemaJson!)
        return makeCString("null")
    }

    func sendMessage(
        _ runtime: UnsafeMutableRawPointer?,
        _ inputJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        sentMessageJson = String(cString: inputJson!)
        return makeCString(Self.turnJson(state: "waiting_tool"))
    }

    func pendingToolRequests(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString("""
        [{
          "run_id": "run_3",
          "session_id": "session_1",
          "tool_call_entry_id": "entry_6",
          "tool_call_id": "call_1",
          "tool_name": "debug.echo",
          "arguments_json": "{}"
        }]
        """)
    }

    func pendingApprovalRequests(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString("""
        [{
          "approval_id": "approval_1",
          "message": "Approve?",
          "requires_local_authentication": true
        }]
        """)
    }

    func submitToolResult(
        _ runtime: UnsafeMutableRawPointer?,
        _ runId: UnsafePointer<CChar>?,
        _ resultJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        submittedToolResultJson = String(cString: resultJson!)
        return makeCString(Self.turnJson(state: "completed"))
    }

    func submitApprovalResponse(
        _ runtime: UnsafeMutableRawPointer?,
        _ responseJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        submittedApprovalResponseJson = String(cString: responseJson!)
        return makeCString(Self.turnJson(state: "completed"))
    }

    func cancel(
        _ runtime: UnsafeMutableRawPointer?,
        _ runId: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        makeCString("""
        {
          "id": "entry_9",
          "session_id": "session_1",
          "parent_id": "entry_8",
          "run_id": "run_3",
          "sequence": 8,
          "depth": 4,
          "kind": "run_cancelled",
          "payload": "cancelled",
          "blob_refs": []
        }
        """)
    }

    func latestPromptDebugSnapshot(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString(#"{"rendered_text":"system\npolicy"}"#)
    }

    private func makeCString(_ string: String) -> UnsafeMutablePointer<CChar> {
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
          "run_id": "run_3",
          "state": "\(state)",
          "events": [],
          "pending_tool_call_id": null
        }
        """
    }
}

private func decodedObject(_ json: String) throws -> [String: Any] {
    let data = json.data(using: .utf8)!
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
