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
    func rustRuntimeConfigurationEncodesNamedLocalLLMProviderConfiguration() throws {
        let provider = RustRuntimeProviderConfiguration.namedLocalLLM(
            providerId: "local_llm.litert",
            displayName: "LiteRT",
            model: "local.litert.simulator",
            modelConfigJson: #"{"backend":"litert","model_path":"/tmp/model.task"}"#,
            maxContextTokens: 1024
        )
        let data = try JSONEncoder().encode(provider)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(RustRuntimeProviderConfiguration.self, from: data)

        #expect(provider.bootstrapProviderId == "local_llm.litert")
        #expect(object["kind"] as? String == "local_llm")
        #expect(object["provider_id"] as? String == "local_llm.litert")
        #expect(object["display_name"] as? String == "LiteRT")
        #expect(decoded == provider)
    }

    @Test
    func namedLocalLLMProviderDecodingUsesRustCompatibleDefaults() throws {
        let data = Data(#"{"kind":"local_llm","provider_id":"local_llm.llama_cpp","model":"local.gguf","model_config_json":"{}","max_context_tokens":2048}"#.utf8)
        let provider = try JSONDecoder().decode(RustRuntimeProviderConfiguration.self, from: data)

        #expect(provider == .namedLocalLLM(
            providerId: "local_llm.llama_cpp",
            displayName: "Local LLM",
            model: "local.gguf",
            modelConfigJson: "{}",
            maxContextTokens: 2048
        ))
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
        let summaries = try await client?.conversationSummaries()
        let forkedSession = try await client?.forkSession(sessionId: "session_1", leafId: "entry_leaf")
        let activeBranch = try await client?.activeBranch(sessionId: "session_1", leafId: "entry_leaf")
        try await client?.archiveSession(sessionId: "session_1")
        try await client?.renameSession(sessionId: "session_1", title: "Travel plan")
        try await client?.updateRuntimeOptions(RuntimeOptionsDTO(
            systemPrompt: "custom system",
            runtimePolicy: "custom policy",
            temperature: 0.25,
            topP: 0.8
        ))
        try await client?.deleteSession(sessionId: "session_1")

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
        #expect(summaries?.first?.sessionId == "session_1")
        #expect(summaries?.first?.activeLeafId == "entry_leaf")
        #expect(forkedSession == "session_forked")
        #expect(activeBranch?.first?.id == "entry_leaf")

        let registeredSchema = try decodedObject(try #require(probe.registeredSchemaJson))
        let permissionState = try decodedObject(try #require(probe.permissionStateJson))
        let sentMessage = try decodedObject(try #require(probe.sentMessageJson))
        let submittedResult = try decodedObject(try #require(probe.submittedToolResultJson))
        let approvalResponse = try decodedObject(try #require(probe.submittedApprovalResponseJson))
        let setProvider = try decodedObject(try #require(probe.setProviderJson))
        let runtimeOptions = try decodedObject(try #require(probe.runtimeOptionsJson))

        #expect(registeredSchema["risk_level"] as? String == "confirm")
        #expect(permissionState["scope"] as? String == "calendar.events")
        #expect(permissionState["state"] as? String == "denied")
        #expect(sentMessage["parent_event_id"] as? String == "entry_parent")
        #expect(sentMessage["text"] as? String == "use tool")
        #expect(submittedResult["retention"] as? String == "run_only")
        #expect(approvalResponse["reason"] is NSNull)
        #expect(setProvider["session_id"] as? String == "session_1")
        #expect(setProvider["provider_id"] as? String == "mock")
        #expect(runtimeOptions["system_prompt"] as? String == "custom system")
        #expect(runtimeOptions["runtime_policy"] as? String == "custom policy")
        #expect(runtimeOptions["temperature"] as? Double == 0.25)
        #expect(runtimeOptions["top_p"] as? Double == 0.8)
        #expect(probe.forkSessionId == "session_1")
        #expect(probe.forkLeafId == "entry_leaf")
        #expect(probe.activeBranchSessionId == "session_1")
        #expect(probe.activeBranchLeafId == "entry_leaf")
        #expect(probe.archivedSessionId == "session_1")
        #expect(probe.renamedSessionId == "session_1")
        #expect(probe.renamedSessionTitle == "Travel plan")
        #expect(probe.deletedSessionId == "session_1")

        client = nil

        #expect(probe.freedRuntimeHandles == 1)
        #expect(probe.freedStrings == 21)
    }

    @Test
    func rustRuntimeClientStartRunAndDebugArchiveUseApplicationServiceBoundary() async throws {
        let probe = RuntimeCFunctionProbe()
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        let handle = try await client?.startRun(StartRunRequestDTO(
            agentProfileId: "profile_1",
            userIntent: "research this"
        ))
        let archive = try await client?.loadDebugArchive("run_agent_os")

        let startRun = try decodedObject(try #require(probe.startRunJson))
        #expect(handle?.runId == "run_agent_os")
        #expect(startRun["agent_profile_id"] as? String == "profile_1")
        #expect(startRun["user_intent"] as? String == "research this")
        #expect(startRun["permission_state"] == nil)
        #expect(startRun["local_bindings"] == nil)
        #expect(probe.debugArchiveRunId == "run_agent_os")
        #expect(archive?.runId == "run_agent_os")
        #expect(archive?.state == .completed)

        client = nil

        #expect(probe.freedStrings == 2)
        #expect(probe.freedRuntimeHandles == 1)
    }

    @Test
    func rustRuntimeClientGatewayDispatchesConversationExecutionBoundaryOperations() async throws {
        let probe = RuntimeCFunctionProbe()
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())
        let frameRef = conversationRunFrameRef()

        let prepared: PreparedUserTurnDTO = try await client!.request(
            .prepareUserTurn,
            PrepareUserTurnRequestDTO(
                sessionId: "session_1",
                parentEventId: "entry_parent",
                text: "ship it"
            ),
            as: PreparedUserTurnDTO.self
        )
        let run: RunHandleDTO = try await client!.request(
            .startRun,
            StartExecutionRequestDTO(
                agentProfileId: "profile_1",
                profileRevisionId: 1,
                userIntent: "ship it",
                conversationRunFrameRef: frameRef,
                options: ExecutionOptionsDTO(modelId: "model_1", temperature: 0.2)
            ),
            as: RunHandleDTO.self
        )
        let commit: ConversationCommitResultDTO = try await client!.request(
            .commitAssistantResult,
            CommitAssistantResultRequestDTO(
                runId: "run_agent_os",
                finalMessageId: "final_1",
                conversationRunFrameRef: frameRef
            ),
            as: ConversationCommitResultDTO.self
        )
        let profile: AgentProfileDTO = try await client!.request(
            .buildAgent,
            BuildAgentRequestDTO(templateId: "template_1"),
            as: AgentProfileDTO.self
        )
        let contextPreview: BuilderContextPreviewResponseDTO = try await client!.request(
            .previewContext,
            BuilderContextPreviewRequestDTO(
                draft: AgentBuilderDraftDTO(
                    profileId: "profile_1",
                    templateId: "template_1",
                    systemPrompt: "system",
                    selectedToolIds: ["web.fetch_url_text"],
                    contextStepIds: ["system_prompt", "tool_results"]
                ),
                sampleUserMessage: "hello"
            ),
            as: BuilderContextPreviewResponseDTO.self
        )
        let _: EmptyAgentOSResponseDTO = try await client!.request(
            .approveTool,
            ApproveToolRequestDTO(id: "approval_1", decision: ApprovalDecisionDTO(approved: true)),
            as: EmptyAgentOSResponseDTO.self
        )
        let _: EmptyAgentOSResponseDTO = try await client!.request(
            .updateRuntimeOptions,
            RuntimeOptionsDTO(
                systemPrompt: "system",
                runtimePolicy: "policy",
                temperature: 0.1,
                topP: 0.9
            ),
            as: EmptyAgentOSResponseDTO.self
        )
        let submitted: AgentTurnResultDTO = try await client!.request(
            .submitToolResult,
            SubmitToolResultRequestDTO(
                runId: "run_agent_os",
                result: ToolResultDTO(
                    displayText: "tool ok",
                    modelText: "tool model text",
                    structuredJson: "{}",
                    auditText: "tool audit",
                    sensitivity: .public,
                    retention: .runOnly,
                    isError: false
                )
            ),
            as: AgentTurnResultDTO.self
        )

        let preparedRequest = try decodedObject(try #require(probe.prepareUserTurnJson))
        let startRequest = try decodedObject(try #require(probe.startRunJson))
        let commitRequest = try decodedObject(try #require(probe.commitAssistantResultJson))
        let buildRequest = try decodedObject(try #require(probe.buildAgentJson))
        let previewRequest = try decodedObject(try #require(probe.previewContextJson))
        let approveRequest = try decodedObject(try #require(probe.approveToolJson))
        let submitRequest = try decodedObject(try #require(probe.submittedToolResultJson))

        #expect(prepared.sessionId == "session_1")
        #expect(prepared.conversationRunFrameRef == frameRef)
        #expect(run.runId == "run_agent_os")
        #expect(run.replayFromSequence == 0)
        #expect(commit.committedMessageId == "assistant.final_1")
        #expect(profile.profileId == "profile_1")
        #expect(contextPreview.segments.map(\.id) == ["system_prompt"])
        #expect(submitted.state == .completed)
        #expect(preparedRequest["parent_event_id"] as? String == "entry_parent")
        #expect((startRequest["conversation_run_frame_ref"] as? [String: Any])?["frame_id"] as? String == "frame_1")
        #expect(startRequest["profile_revision_id"] as? Int == 1)
        let forbiddenFrameKey = ["conversation", "frame", "ref"].joined(separator: "_")
        #expect(startRequest[forbiddenFrameKey] == nil)
        #expect(commitRequest["run_id"] as? String == "run_agent_os")
        #expect((commitRequest["conversation_run_frame_ref"] as? [String: Any])?["user_turn_id"] as? String == "entry_user")
        #expect(buildRequest["template_id"] as? String == "template_1")
        #expect((previewRequest["draft"] as? [String: Any])?["system_prompt"] as? String == "system")
        #expect(previewRequest["sample_user_message"] as? String == "hello")
        #expect(approveRequest["id"] as? String == "approval_1")
        #expect((approveRequest["decision"] as? [String: Any])?["approved"] as? Bool == true)
        #expect(probe.submittedToolResultRunId == "run_agent_os")
        #expect(submitRequest["model_text"] as? String == "tool model text")

        client = nil

        #expect(probe.freedStrings == 8)
        #expect(probe.freedRuntimeHandles == 1)
    }

    @Test
    func rustRuntimeClientGatewayStreamsReplayAndLiveExecutionEvents() async throws {
        let probe = RuntimeCFunctionProbe()
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        let stream = client!.stream(
            .observeEvents,
            ObserveExecutionEventsRequestDTO(runId: "run_agent_os", fromSequence: 4)
        )
        var events: [RuntimeEventDTO] = []
        for try await event in stream {
            events.append(event)
        }

        let observeRequest = try decodedObject(try #require(probe.observeEventsJson))

        #expect(events.map(\.sequence) == [5, 6])
        #expect(events.map(\.payload) == ["run.started", "run.completed"])
        #expect(observeRequest["run_id"] as? String == "run_agent_os")
        #expect(observeRequest["from_sequence"] as? Int == 4)

        client = nil

        #expect(probe.freedStrings == 1)
        #expect(probe.freedRuntimeHandles == 1)
    }

    @Test
    func observeEventsOverflowFails() async throws {
        let probe = RuntimeCFunctionProbe()
        probe.observeEventsToEmit = runtimeEventStreamBufferLimit + 1
        probe.observeFailsOnCallbackError = true
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        let stream = client!.stream(
            .observeEvents,
            ObserveExecutionEventsRequestDTO(runId: "run_agent_os", fromSequence: 0)
        )

        for _ in 0..<100
        where !probe.observeCallbackReturnValues.contains(where: { $0 != 0 })
            && probe.observeCallbackReturnValues.count < runtimeEventStreamBufferLimit + 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // Unlike turn streams, observeEvents has no final result fallback. If
        // the bounded buffer overflows, lifecycle events must not be reported
        // to Rust as successfully delivered.
        do {
            for try await _ in stream {}
            Issue.record("Expected observeEvents overflow to surface a bridge error")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "ffi")
            #expect(error.message.contains("runtime event stream buffer overflow"))
        }

        #expect(probe.observeCallbackReturnValues.contains { $0 != 0 })

        client = nil
    }

    @Test
    func mockRuntimeClientSupportsSplitConversationAndExecutionContracts() async throws {
        let frameRef = conversationRunFrameRef()
        let event = RuntimeEventDTO(
            id: "event_5",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_mock",
            sequence: 5,
            depth: 0,
            kind: .unknown(raw: "execution.event"),
            payload: "run.completed",
            blobRefs: []
        )
        let mock = MockRuntimeClient(
            sessionIds: ["session_1"],
            conversationSummaries: [
                ConversationSummaryDTO(
                    sessionId: "session_1",
                    title: "Planning",
                    activeLeafId: "entry_user",
                    lastEventId: "entry_user",
                    lastUpdatedSequence: 4
                )
            ],
            activeBranch: [event],
            agentProfiles: [
                AgentProfileDTO(
                    profileId: "profile_1",
                    profileRevisionId: 1,
                    displayName: "Planner"
                )
            ],
            executionEventsByRunId: ["run_mock": [event]]
        )

        let sessions = try await mock.listSessions()
        let prepared = try await mock.prepareUserTurn(PrepareUserTurnRequestDTO(
            sessionId: "session_1",
            parentEventId: "entry_parent",
            text: "continue"
        ))
        let handle = try await mock.startRun(StartExecutionRequestDTO(
            agentProfileId: "profile_1",
            profileRevisionId: 1,
            userIntent: "continue",
            conversationRunFrameRef: frameRef
        ))
        var observed: [RuntimeEventDTO] = []
        for try await event in mock.observeEvents(runId: "run_mock", fromSequence: 4) {
            observed.append(event)
        }
        let commit = try await mock.commitAssistantResult(CommitAssistantResultRequestDTO(
            runId: "run_mock",
            finalMessageId: "final_1",
            conversationRunFrameRef: frameRef
        ))

        #expect(sessions.map(\.sessionId) == ["session_1"])
        #expect(prepared.sessionId == "session_1")
        #expect(prepared.conversationRunFrameRef.sessionId == "session_1")
        #expect(handle.runId == "run_mock")
        #expect(observed == [event])
        #expect(commit.committedMessageId == "assistant.run_mock.final_1")
        #expect(await mock.preparedUserTurnRequests.count == 1)
        #expect(await mock.startedExecutionRequests.count == 1)
        #expect(await mock.commitAssistantResultRequests.count == 1)
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
    func rustRuntimeClientDecodesPanicErrorEnvelope() async throws {
        let probe = RuntimeCFunctionProbe()
        probe.createSessionResponse = #"{"error":{"kind":"panic","message":"rust ffi panic: ffi test panic"}}"#
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        do {
            _ = try await client?.createSession()
            Issue.record("Expected createSession to throw")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "panic")
            #expect(error.message.contains("rust ffi panic"))
        }

        client = nil

        #expect(probe.freedStrings == 1)
        #expect(probe.freedRuntimeHandles == 1)
    }

    @Test
    func rustRuntimeClientTurnsNullNormalResponseIntoFfiError() async throws {
        let probe = RuntimeCFunctionProbe()
        probe.createSessionResponse = nil
        var client: RustRuntimeClient? = try RustRuntimeClient(functions: probe.table())

        do {
            _ = try await client?.createSession()
            Issue.record("Expected createSession to throw")
        } catch let error as RuntimeBridgeError {
            #expect(error.kind == "ffi")
            #expect(error.message == "runtime bridge returned a null string")
        }

        client = nil

        #expect(probe.freedStrings == 0)
        #expect(probe.freedRuntimeHandles == 1)
    }

    @Test
    func runtimeBridgeErrorUsesBridgeMessageAsLocalizedDescription() {
        let error = RuntimeBridgeError(
            kind: "provider",
            message: "start on-device image stream failed"
        )

        #expect(error.localizedDescription == "start on-device image stream failed")
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
            store: .sqlite(path: databaseURL.path),
            agentOS: RustAgentOSConfiguration(seedDevelopmentProfile: true)
        )

        var firstClient: RustRuntimeClient? = try RustRuntimeClient(configuration: configuration)
        let createdSession = try await firstClient!.createSession()
        let prepared: PreparedUserTurnDTO = try await firstClient!.request(
            .prepareUserTurn,
            PrepareUserTurnRequestDTO(
                sessionId: createdSession,
                parentEventId: nil,
                text: "live bridge run"
            ),
            as: PreparedUserTurnDTO.self
        )
        let run: RunHandleDTO = try await firstClient!.request(
            .startRun,
            StartExecutionRequestDTO(
                agentProfileId: "profile_1",
                profileRevisionId: 1,
                userIntent: "live bridge run",
                conversationRunFrameRef: prepared.conversationRunFrameRef
            ),
            as: RunHandleDTO.self
        )
        var events: [RuntimeEventDTO] = []
        for try await event in firstClient!.stream(
            .observeEvents,
            ObserveExecutionEventsRequestDTO(
                runId: run.runId,
                fromSequence: run.replayFromSequence
            )
        ) {
            events.append(event)
        }
        firstClient = nil

        let secondClient = try RustRuntimeClient(configuration: configuration)
        let sessionIds = try await secondClient.sessionIds()

        #expect(prepared.sessionId == createdSession)
        #expect(run.runId == "run_1")
        #expect(events.map(\.payload).contains("run.started"))
        #expect(events.map(\.payload).contains("run.completed"))
        #expect(sessionIds.contains(createdSession))
    }
}

private final class RuntimeCFunctionProbe: @unchecked Sendable {
    var createSessionResponse: String? = #""session_1""#
    var freedStrings = 0
    var freedRuntimeHandles = 0
    var registeredSchemaJson: String?
    var permissionStateJson: String?
    var sentMessageJson: String?
    var submittedToolResultRunId: String?
    var submittedToolResultJson: String?
    var submittedApprovalResponseJson: String?
    var setProviderJson: String?
    var runtimeOptionsJson: String?
    var startRunJson: String?
    var debugArchiveRunId: String?
    var listAgentProfilesJson: String?
    var buildAgentJson: String?
    var previewContextJson: String?
    var prepareUserTurnJson: String?
    var observeEventsJson: String?
    var observeEventsToEmit: Int?
    // Simulates Rust returning an error envelope after Swift reports callback failure.
    var observeFailsOnCallbackError = false
    var commitAssistantResultJson: String?
    var approveToolJson: String?
    var cancelRunJson: String?
    var forkSessionId: String?
    var forkLeafId: String?
    var activeBranchSessionId: String?
    var activeBranchLeafId: String?
    var archivedSessionId: String?
    var renamedSessionId: String?
    var renamedSessionTitle: String?
    var deletedSessionId: String?

    private let handle = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    private let lock = NSLock()
    private var observeCallbackStatuses: [CInt] = []

    var observeCallbackReturnValues: [CInt] {
        lock.lock()
        defer { lock.unlock() }
        return observeCallbackStatuses
    }

    func table() -> RustRuntimeCFunctionTable {
        RustRuntimeCFunctionTable(
            makeRuntime: makeRuntime,
            freeRuntime: freeRuntime,
            freeString: freeString,
            createSession: createSession,
            sessionIds: sessionIds,
            conversationSummaries: conversationSummaries,
            forkSession: forkSession,
            activeBranch: activeBranch,
            archiveSession: archiveSession,
            renameSession: renameSession,
            updateRuntimeOptions: updateRuntimeOptions,
            deleteSession: deleteSession,
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
            setProvider: setProvider,
            startRun: startRun,
            loadDebugArchive: loadDebugArchive,
            listAgentProfiles: listAgentProfiles,
            buildAgent: buildAgent,
            prepareUserTurn: prepareUserTurn,
            observeEvents: observeEvents,
            observeEventsStreaming: observeEventsStreaming,
            commitAssistantResult: commitAssistantResult,
            approveTool: approveTool,
            cancelRun: cancelRun,
            previewContext: previewContext
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
        guard let createSessionResponse else {
            return nil
        }
        return makeCString(createSessionResponse)
    }

    func sessionIds(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString(#"["session_1"]"#)
    }

    func conversationSummaries(_ runtime: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? {
        makeCString("""
        [{
          "session_id": "session_1",
          "title": "Hello",
          "active_leaf_id": "entry_leaf",
          "last_event_id": "entry_leaf",
          "last_updated_sequence": 4
        }]
        """)
    }

    func forkSession(
        _ runtime: UnsafeMutableRawPointer?,
        _ sessionId: UnsafePointer<CChar>?,
        _ leafId: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        forkSessionId = String(cString: sessionId!)
        forkLeafId = String(cString: leafId!)
        return makeCString(#""session_forked""#)
    }

    func activeBranch(
        _ runtime: UnsafeMutableRawPointer?,
        _ sessionId: UnsafePointer<CChar>?,
        _ leafId: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        activeBranchSessionId = String(cString: sessionId!)
        activeBranchLeafId = leafId.map { String(cString: $0) }
        return makeCString("""
        [{
          "id": "entry_leaf",
          "session_id": "session_1",
          "parent_id": null,
          "run_id": "run_3",
          "sequence": 4,
          "depth": 0,
          "kind": "assistant_message_completed",
          "payload": "done",
          "blob_refs": []
        }]
        """)
    }

    func archiveSession(
        _ runtime: UnsafeMutableRawPointer?,
        _ sessionId: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        archivedSessionId = String(cString: sessionId!)
        return makeCString("null")
    }

    func renameSession(
        _ runtime: UnsafeMutableRawPointer?,
        _ sessionId: UnsafePointer<CChar>?,
        _ title: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        renamedSessionId = String(cString: sessionId!)
        renamedSessionTitle = String(cString: title!)
        return makeCString("null")
    }

    func updateRuntimeOptions(
        _ runtime: UnsafeMutableRawPointer?,
        _ optionsJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        runtimeOptionsJson = String(cString: optionsJson!)
        return makeCString("null")
    }

    func deleteSession(
        _ runtime: UnsafeMutableRawPointer?,
        _ sessionId: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        deletedSessionId = String(cString: sessionId!)
        return makeCString("null")
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
          "requires_local_authentication": true,
          "scope": {
            "kind": "operation",
            "operation": "tool.debug.confirm"
          }
        }]
        """)
    }

    func submitToolResult(
        _ runtime: UnsafeMutableRawPointer?,
        _ runId: UnsafePointer<CChar>?,
        _ resultJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        submittedToolResultRunId = String(cString: runId!)
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

    func startRun(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        startRunJson = String(cString: requestJson!)
        return makeCString(#"{"run_id":"run_agent_os"}"#)
    }

    func loadDebugArchive(
        _ runtime: UnsafeMutableRawPointer?,
        _ runId: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        debugArchiveRunId = String(cString: runId!)
        return makeCString("""
        {
          "run_id": "\(debugArchiveRunId ?? "run_agent_os")",
          "state": "completed",
          "events": [
            { "id": "event_1", "code": "run.started", "title": "Run started" }
          ],
          "checkpoints": [
            { "id": "checkpoint_1", "title": "Done", "can_resume": false }
          ]
        }
        """)
    }

    func listAgentProfiles(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        listAgentProfilesJson = requestJson.map { String(cString: $0) }
        return makeCString("""
        [{
          "profile_id": "profile_1",
          "profile_revision_id": 1,
          "display_name": "Planner"
        }]
        """)
    }

    func buildAgent(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        buildAgentJson = String(cString: requestJson!)
        return makeCString("""
        {
          "profile_id": "profile_1",
          "profile_revision_id": 1,
          "display_name": "Planner"
        }
        """)
    }

    func previewContext(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        previewContextJson = String(cString: requestJson!)
        return makeCString("""
        {
          "is_preview_only": false,
          "segments": [
            {
              "id": "system_prompt",
              "title": "System Prompt",
              "source_label": "prompt",
              "trust_level": "trusted_app_policy",
              "is_enabled": true,
              "preview_text": "system"
            }
          ],
          "token_estimate": 8,
          "warnings": [],
          "missing_inputs": []
        }
        """)
    }

    func prepareUserTurn(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        prepareUserTurnJson = String(cString: requestJson!)
        return makeCString("""
        {
          "session_id": "session_1",
          "user_message_id": "entry_user",
          "conversation_run_frame_ref": {
            "frame_id": "frame_1",
            "session_id": "session_1",
            "branch_head_id": "entry_parent",
            "user_turn_id": "entry_user"
          },
          "frame_preview": null
        }
        """)
    }

    func observeEvents(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        observeEventsJson = String(cString: requestJson!)
        return makeCString(Self.executionEventsJson)
    }

    func observeEventsStreaming(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?,
        _ callback: RustRuntimeCFunctionTable.RuntimeEventCallback?,
        _ userData: UnsafeMutableRawPointer?
    ) -> UnsafeMutablePointer<CChar>? {
        observeEventsJson = String(cString: requestJson!)
        for eventJson in observeEventJsonLines() {
            let status = eventJson.withCString { pointer in
                callback?(pointer, userData)
            }
            lock.lock()
            observeCallbackStatuses.append(status ?? 0)
            lock.unlock()
            if status != 0 && observeFailsOnCallbackError {
                return makeCString(#"{"error":{"kind":"ffi","message":"event stream callback returned non-zero"}}"#)
            }
        }
        return makeCString("null")
    }

    func commitAssistantResult(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        commitAssistantResultJson = String(cString: requestJson!)
        return makeCString("""
        {
          "committed_message_id": "assistant.final_1",
          "already_committed": false
        }
        """)
    }

    func approveTool(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        approveToolJson = String(cString: requestJson!)
        return makeCString("null")
    }

    func cancelRun(
        _ runtime: UnsafeMutableRawPointer?,
        _ requestJson: UnsafePointer<CChar>?
    ) -> UnsafeMutablePointer<CChar>? {
        cancelRunJson = String(cString: requestJson!)
        return "run_agent_os".withCString { runId in
            cancel(runtime, runId)
        }
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

    private static let executionEventJsonLines = [
        """
        {
          "id": "event_5",
          "session_id": "session_1",
          "parent_id": null,
          "run_id": "run_agent_os",
          "sequence": 5,
          "depth": 0,
          "kind": "execution.event",
          "payload": "run.started",
          "blob_refs": []
        }
        """,
        """
        {
          "id": "event_6",
          "session_id": "session_1",
          "parent_id": null,
          "run_id": "run_agent_os",
          "sequence": 6,
          "depth": 0,
          "kind": "execution.event",
          "payload": "run.completed",
          "blob_refs": []
        }
        """
    ]

    private func observeEventJsonLines() -> [String] {
        guard let observeEventsToEmit else {
            return Self.executionEventJsonLines
        }
        return (0..<observeEventsToEmit).map { index in
            let sequence = index + 1
            let isFinal = index == observeEventsToEmit - 1
            let kind = isFinal ? "execution.event" : "assistant_text_delta"
            let payload = isFinal ? "run.completed" : "delta.\(sequence)"
            return """
            {
              "id": "event_\(sequence)",
              "session_id": "session_1",
              "parent_id": null,
              "run_id": "run_agent_os",
              "sequence": \(sequence),
              "depth": 0,
              "kind": "\(kind)",
              "payload": "\(payload)",
              "blob_refs": []
            }
            """
        }
    }

    private static let executionEventsJson = "[\(executionEventJsonLines.joined(separator: ","))]"
}

private func decodedObject(_ json: String) throws -> [String: Any] {
    let data = json.data(using: .utf8)!
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func conversationRunFrameRef() -> ConversationRunFrameRefDTO {
    ConversationRunFrameRefDTO(
        frameId: "frame_1",
        sessionId: "session_1",
        branchHeadId: "entry_parent",
        userTurnId: "entry_user"
    )
}
