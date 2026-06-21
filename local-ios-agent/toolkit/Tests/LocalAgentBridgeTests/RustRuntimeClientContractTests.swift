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
            promptDebugSnapshot: PromptDebugSnapshotDTO(renderedText: "debug"),
            providerProfiles: [
                ProviderProfileDTO(
                    id: "mock",
                    displayName: "Mock Provider",
                    kind: .mock,
                    maxContextTokens: 100
                )
            ],
            activeProvider: ProviderProfileDTO(
                id: "mock",
                displayName: "Mock Provider",
                kind: .mock,
                maxContextTokens: 100
            )
        )

        let created = try await mock.createSession()
        let ids = try await mock.sessionIds()
        let sent = try await mock.sendMessage(
            sessionId: created,
            parentEventId: nil,
            text: "hello"
        )
        let snapshot = try await mock.latestPromptDebugSnapshot()
        let profiles = try await mock.providerProfiles()
        let activeProvider = try await mock.activeProvider()
        let providerEvent = try await mock.setProvider(sessionId: created, providerId: "mock")
        try await mock.setPermissionState(scope: "calendar.events", state: .denied)
        let messages = await mock.sentMessages
        let permissions = await mock.permissionStates

        #expect(created == "session_2")
        #expect(ids == ["session_existing", "session_2"])
        #expect(sent == turn)
        #expect(snapshot?.renderedText == "debug")
        #expect(profiles.map(\.id) == ["mock"])
        #expect(activeProvider.id == "mock")
        #expect(providerEvent.kind == .providerChanged)
        #expect(messages == [
            MockRuntimeClient.SentMessage(
                sessionId: "session_2",
                parentEventId: nil,
                text: "hello"
            )
        ])
        #expect(permissions == [
            MockRuntimeClient.PermissionStateSubmission(
                scope: "calendar.events",
                state: .denied
            )
        ])
    }

    @Test
    func rustRuntimeConfigurationEncodesDesktopProviderConfiguration() throws {
        let configuration = RustRuntimeConfiguration(
            systemPrompt: "configured system",
            runtimePolicy: "configured policy",
            providerId: "desktop_minicpm",
            store: .inMemory,
            providers: [
                .desktopMiniCPM(
                    endpoint: "http://127.0.0.1:8000/v1/chat/completions",
                    model: "minicpm",
                    maxContextTokens: 4096
                )
            ]
        )

        let data = try JSONEncoder().encode(configuration)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        let desktop = try #require(providers.first)

        #expect(object["provider_id"] as? String == "desktop_minicpm")
        #expect(desktop["kind"] as? String == "desktop_minicpm")
        #expect(desktop["endpoint"] as? String == "http://127.0.0.1:8000/v1/chat/completions")
        #expect(desktop["model"] as? String == "minicpm")
        #expect(desktop["max_context_tokens"] as? Int == 4096)
    }

    @Test
    func rustRuntimeConfigurationEncodesLocalLLMProviderConfiguration() throws {
        let configuration = RustRuntimeConfiguration(
            systemPrompt: "configured system",
            runtimePolicy: "configured policy",
            providerId: "local_llm",
            store: .inMemory,
            providers: [
                .localLLM(
                    model: "local.gguf.simulator",
                    modelConfigJson: #"{"backend":"mock","model_path":"/tmp/mock.gguf"}"#,
                    maxContextTokens: 2048
                ),
            ]
        )

        let data = try JSONEncoder().encode(configuration)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(object["providers"] as? [[String: Any]])
        let local = try #require(providers.first)

        #expect(object["provider_id"] as? String == "local_llm")
        #expect(local["kind"] as? String == "local_llm")
        #expect(local["model"] as? String == "local.gguf.simulator")
        #expect(local["model_config_json"] as? String == #"{"backend":"mock","model_path":"/tmp/mock.gguf"}"#)
        #expect(local["max_context_tokens"] as? Int == 2048)
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
        try await client?.setPermissionState(scope: "calendar.events", state: .denied)
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
        let profiles = try await client?.providerProfiles()
        let activeProvider = try await client?.activeProvider()
        let providerEvent = try await client?.setProvider(
            sessionId: "session_1",
            providerId: "mock"
        )

        #expect(turn?.state == .waitingTool)
        #expect(pendingTools?.first?.runId == "run_3")
        #expect(pendingApprovals?.first?.approvalId == "approval_1")
        #expect(pendingApprovals?.first?.runId == "run_3")
        #expect(pendingApprovals?.first?.toolCallEntryId == "entry_6")
        #expect(submittedTool?.state == .completed)
        #expect(submittedApproval?.runId == "run_3")
        #expect(cancelled?.kind == .runCancelled)
        #expect(snapshot?.renderedText == "system\npolicy")
        #expect(profiles?.map(\.id) == ["mock"])
        #expect(activeProvider?.id == "mock")
        #expect(providerEvent?.kind == .providerChanged)

        let registeredSchema = try decodedObject(try #require(probe.registeredSchemaJson))
        let permissionState = try decodedObject(try #require(probe.permissionStateJson))
        let sentMessage = try decodedObject(try #require(probe.sentMessageJson))
        let submittedResult = try decodedObject(try #require(probe.submittedToolResultJson))
        let approvalResponse = try decodedObject(try #require(probe.submittedApprovalResponseJson))
        let setProvider = try decodedObject(try #require(probe.setProviderJson))

        #expect(registeredSchema["risk_level"] as? String == "confirm")
        #expect(permissionState["scope"] as? String == "calendar.events")
        #expect(permissionState["state"] as? String == "denied")
        #expect(sentMessage["parent_event_id"] as? String == "entry_parent")
        #expect(sentMessage["text"] as? String == "use tool")
        #expect(submittedResult["retention"] as? String == "run_only")
        #expect(approvalResponse["reason"] is NSNull)
        #expect(setProvider["session_id"] as? String == "session_1")
        #expect(setProvider["provider_id"] as? String == "mock")

        client = nil

        #expect(probe.freedRuntimeHandles == 1)
        #expect(probe.freedStrings == 14)
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

    @Test
    func rustRuntimeClientLiveUsesLinkedCBridge() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let configuration = RustRuntimeConfiguration(
            systemPrompt: "configured system",
            runtimePolicy: "configured policy",
            providerId: "mock",
            store: .sqlite(path: databaseURL.path)
        )

        var firstClient: RustRuntimeClient? = try RustRuntimeClient(configuration: configuration)
        let createdSession = try await firstClient?.createSession()
        firstClient = nil

        let secondClient = try RustRuntimeClient(configuration: configuration)
        let sessionIds = try await secondClient.sessionIds()

        #expect(createdSession != nil)
        #expect(sessionIds.contains(try #require(createdSession)))
    }
}

private final class RuntimeCFunctionProbe: @unchecked Sendable {
    var createSessionResponse = #""session_1""#
    var freedStrings = 0
    var freedRuntimeHandles = 0
    var registeredSchemaJson: String?
    var permissionStateJson: String?
    var sentMessageJson: String?
    var submittedToolResultJson: String?
    var submittedApprovalResponseJson: String?
    var setProviderJson: String?

    private let handle = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    func table() -> RustRuntimeCFunctionTable {
        RustRuntimeCFunctionTable(
            makeRuntime: makeRuntime,
            freeRuntime: freeRuntime,
            freeString: freeString,
            createSession: createSession,
            sessionIds: sessionIds,
            registerToolSchema: registerToolSchema,
            setPermissionState: setPermissionState,
            sendMessage: sendMessage,
            sendMessageStreaming: sendMessageStreaming,
            pendingToolRequests: pendingToolRequests,
            pendingApprovalRequests: pendingApprovalRequests,
            submitToolResult: submitToolResult,
            submitToolResultStreaming: submitToolResultStreaming,
            submitApprovalResponse: submitApprovalResponse,
            cancel: cancel,
            latestPromptDebugSnapshot: latestPromptDebugSnapshot,
            providerProfiles: providerProfiles,
            activeProvider: activeProvider,
            setProvider: setProvider
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

    func setPermissionState(
        _ runtime: UnsafeMutableRawPointer?,
        _ stateJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        permissionStateJson = String(cString: stateJson!)
        return makeCString("null")
    }

    func sendMessage(
        _ runtime: UnsafeMutableRawPointer?,
        _ inputJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        sentMessageJson = String(cString: inputJson!)
        return makeCString(Self.turnJson(state: "waiting_tool"))
    }

    func sendMessageStreaming(
        _ runtime: UnsafeMutableRawPointer?,
        _ inputJson: UnsafePointer<CChar>?,
        _ callback: RustRuntimeCFunctionTable.RuntimeEventCallback?,
        _ userData: UnsafeMutableRawPointer?
    ) -> UnsafeMutablePointer<CChar>? {
        sendMessage(runtime, inputJson)
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
          "run_id": "run_3",
          "tool_call_entry_id": "entry_6",
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

    func submitToolResultStreaming(
        _ runtime: UnsafeMutableRawPointer?,
        _ runId: UnsafePointer<CChar>?,
        _ resultJson: UnsafePointer<CChar>?,
        _ callback: RustRuntimeCFunctionTable.RuntimeEventCallback?,
        _ userData: UnsafeMutableRawPointer?
    ) -> UnsafeMutablePointer<CChar>? {
        submitToolResult(runtime, runId, resultJson)
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

    func providerProfiles(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString("""
        [{
          "id": "mock",
          "display_name": "Mock Provider",
          "kind": "mock",
          "max_context_tokens": 100
        }]
        """)
    }

    func activeProvider(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString("""
        {
          "id": "mock",
          "display_name": "Mock Provider",
          "kind": "mock",
          "max_context_tokens": 100
        }
        """)
    }

    func setProvider(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        setProviderJson = String(cString: requestJson!)
        return makeCString("""
        {
          "id": "entry_10",
          "session_id": "session_1",
          "parent_id": "entry_9",
          "run_id": null,
          "sequence": 9,
          "depth": 5,
          "kind": "provider_changed",
          "payload": "{\\"provider_id\\":\\"mock\\"}",
          "blob_refs": []
        }
        """)
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
