import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Agent runtime service")
struct AgentRuntimeServiceTests {
    @Test("prepare creates a session and registers debug.echo")
    func prepareCreatesSessionAndRegistersDebugEcho() async throws {
        let client = ScriptedRuntimeClient()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.prepare()
        let schemas = await client.registeredToolSchemas

        #expect(state.phase == .ready)
        #expect(state.currentSessionId == "session_1")
        #expect(schemas.map(\.name) == ["debug.echo"])
    }

    @Test("prepare loads provider profiles and active provider")
    func prepareLoadsProviderProfilesAndActiveProvider() async throws {
        let client = ScriptedRuntimeClient()
        await client.setProviderProfilesForTest([
            ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096),
            ProviderProfileDTO(id: "local_llm", displayName: "Local LLM", kind: .localLLM, maxContextTokens: 2048),
        ])
        await client.setActiveProviderForTest(
            ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096)
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.prepare()

        #expect(state.provider.profiles.map(\.id) == ["mock", "local_llm"])
        #expect(state.provider.active?.id == "mock")
    }

    @Test("select provider updates active provider")
    func selectProviderUpdatesActiveProvider() async throws {
        let client = ScriptedRuntimeClient()
        await client.setProviderProfilesForTest([
            ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096),
            ProviderProfileDTO(id: "local_llm", displayName: "Local LLM", kind: .localLLM, maxContextTokens: 2048),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let prepared = try await service.prepare()

        let state = try await service.selectProvider("local_llm", state: prepared)

        #expect(await client.selectedProviders.map(\.providerId) == ["local_llm"])
        #expect(state.provider.active?.id == "local_llm")
    }

    @Test("new chat creates a fresh ready session")
    func newChatCreatesFreshReadySession() async throws {
        let client = ScriptedRuntimeClient()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        var state = try await service.prepare()
        state.messages = [
            AgentMessageViewState(id: "old", role: .user, text: "old", isStreaming: false),
        ]

        let nextState = try await service.newChat(state: state)

        #expect(nextState.phase == .ready)
        #expect(nextState.currentSessionId == "session_2")
        #expect(nextState.messages.isEmpty)
    }

    @Test("load conversations projects runtime summaries")
    func loadConversationsProjectsRuntimeSummaries() async throws {
        let client = ScriptedRuntimeClient()
        await client.setConversationSummariesForTest([
            ConversationSummaryDTO(
                sessionId: "session_2",
                title: "Second chat",
                activeLeafId: "leaf_2",
                lastEventId: "event_2",
                lastUpdatedSequence: 4,
                lastUpdatedAtMillis: 1_719_999_999_000
            ),
            ConversationSummaryDTO(
                sessionId: "session_1",
                title: "First chat",
                activeLeafId: "leaf_1",
                lastEventId: "event_1",
                lastUpdatedSequence: 2
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.loadConversations(
            state: AgentViewState(phase: .ready, currentSessionId: "session_2")
        )

        #expect(state.conversations.conversations.map(\.sessionId) == ["session_2", "session_1"])
        #expect(state.conversations.conversations.first?.title == "Second chat")
        #expect(state.conversations.conversations.first?.activeLeafId == "leaf_2")
        #expect(
            state.conversations.conversations.first?.lastMessageDate
                == Date(timeIntervalSince1970: 1_719_999_999)
        )
    }

    @Test("conversation sections group by recency and filter search")
    func conversationSectionsGroupByRecencyAndFilterSearch() {
        let now = date(year: 2026, month: 6, day: 26, hour: 12)
        let conversations = [
            conversation("today", title: "Trip today", date: date(year: 2026, month: 6, day: 26, hour: 9)),
            conversation("yesterday", title: "Trip yesterday", date: date(year: 2026, month: 6, day: 25, hour: 18)),
            conversation("before", title: "Trip before", date: date(year: 2026, month: 6, day: 24, hour: 18)),
            conversation("week", title: "Trip week", date: date(year: 2026, month: 6, day: 22, hour: 18)),
            conversation("month", title: "Trip month", date: date(year: 2026, month: 6, day: 21, hour: 18)),
            conversation("may", title: "Trip may", date: date(year: 2026, month: 5, day: 12, hour: 18)),
            conversation("other", title: "Notes", date: date(year: 2026, month: 6, day: 24, hour: 8)),
            conversation(
                "content",
                title: "Untitled",
                date: date(year: 2026, month: 6, day: 26, hour: 8),
                searchText: "hidden trip notes"
            ),
        ]

        let sections = ConversationService.groupConversations(
            conversations,
            searchQuery: "trip",
            now: now,
            calendar: gregorianCalendar
        )

        #expect(sections.map(\.title) == ["今天", "昨天", "前天", "本周", "本月", "5月"])
        #expect(sections.flatMap(\.conversations).map(\.sessionId) == [
            "today", "content", "yesterday", "before", "week", "month", "may",
        ])
    }

    @Test("rename conversation persists title and reloads summaries")
    func renameConversationPersistsTitleAndReloadsSummaries() async throws {
        let client = ScriptedRuntimeClient()
        await client.setConversationSummariesForTest([
            ConversationSummaryDTO(
                sessionId: "session_1",
                title: "Old title",
                activeLeafId: "leaf_1",
                lastEventId: "leaf_1",
                lastUpdatedSequence: 4
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = AgentViewState(phase: .ready, currentSessionId: "session_1")

        let nextState = try await service.renameConversation(
            sessionId: "session_1",
            title: " Travel plan ",
            state: state
        )

        #expect(await client.renamedSessions == [
            ScriptedRuntimeClient.RenamedSession(sessionId: "session_1", title: "Travel plan"),
        ])
        #expect(nextState.conversations.conversations.map(\.title) == ["Travel plan"])
    }

    @Test("send applies prompt and model settings to runtime before inference")
    func sendAppliesPromptAndModelSettingsToRuntimeBeforeInference() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_1", sessionId: "session_1", kind: .userMessage, payload: "hi", runId: "run_1"),
                    event(
                        id: "assistant_1",
                        sessionId: "session_1",
                        parentId: "user_1",
                        kind: .assistantMessageCompleted,
                        payload: "hello",
                        runId: "run_1"
                    ),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        var state = AgentViewState(
            phase: .ready,
            draft: "hi",
            currentSessionId: "session_1",
            promptLibrary: PromptLibraryViewState(sections: [
                PromptSectionViewState(id: "system", name: "System Prompt", content: "Be concise."),
                PromptSectionViewState(id: "style", name: "Style", content: "Use plain language."),
            ]),
            modelSettings: ModelSettingsViewState(temperature: 0.25, topP: 0.8)
        )

        state = try await service.sendMessage(state.draftText, state: state)

        #expect(await client.runtimeOptions == [
            ScriptedRuntimeClient.RuntimeOptionsSubmission(
                systemPrompt: "### System Prompt\nBe concise.\n\n### Style\nUse plain language.",
                runtimePolicy: AgentPromptDefaults.runtimePolicy,
                temperature: 0.25,
                topP: 0.8
            ),
        ])
        #expect(state.messages.map(\.text).contains("hello"))
    }

    @Test("send message uses coordinator when injected")
    @MainActor
    func sendMessageUsesCoordinatorWhenInjected() async throws {
        let coordinator = RecordingChatInteractionCoordinator()
        let client = ScriptedRuntimeClient()
        let service = AgentRuntimeService(
            runtimeClient: client,
            toolDriver: MinimalHostToolDriver(),
            coordinator: coordinator
        )

        var state = AgentViewState(phase: .ready, currentSessionId: "session_1")
        state.modelSettings = ModelSettingsViewState(temperature: 0.25, topP: 0.8)
        state.provider.active = ProviderProfileDTO(
            id: "mock",
            displayName: "Mock",
            kind: .mock,
            maxContextTokens: 100
        )
        let sentState = try await service.sendMessage(
            "hello",
            state: state
        )

        #expect(coordinator.sentMessages == ["hello"])
        #expect(coordinator.agentProfileIds == ["profile_1"])
        #expect(await client.runtimeOptions.map(\.temperature) == [0.25])
        #expect(await client.runtimeOptions.map(\.topP) == [0.8])
        #expect(sentState.phase == .ready)
        #expect(sentState.draft == UserDraftViewState())
    }

    @Test("coordinator path passes seed profile revision")
    @MainActor
    func coordinatorPathPassesSeedProfileRevision() async throws {
        let coordinator = RecordingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            runtimeClient: ScriptedRuntimeClient(),
            toolDriver: MinimalHostToolDriver(),
            coordinator: coordinator
        )

        _ = try await service.sendMessage(
            "hello",
            state: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        #expect(coordinator.agentProfileRevisionIds == [1])
    }

    @Test("coordinator path rejects missing profile revision")
    @MainActor
    func coordinatorPathRejectsMissingProfileRevision() async throws {
        let coordinator = RecordingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            runtimeClient: ScriptedRuntimeClient(),
            toolDriver: MinimalHostToolDriver(),
            coordinator: coordinator
        )
        var state = AgentViewState(phase: .ready, currentSessionId: "session_1")
        state.selectedAgentProfileRevisionId = nil

        do {
            _ = try await service.sendMessage("hello", state: state)
            Issue.record("Expected missing profile revision error")
        } catch AgentRuntimeServiceError.missingAgentProfileRevision {
            #expect(coordinator.sentMessages.isEmpty)
        }
    }

    @Test("coordinator path passes selected profile revision")
    @MainActor
    func coordinatorPathPassesSelectedProfileRevision() async throws {
        let coordinator = RecordingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            runtimeClient: ScriptedRuntimeClient(),
            toolDriver: MinimalHostToolDriver(),
            coordinator: coordinator
        )
        var state = AgentViewState(phase: .ready, currentSessionId: "session_1")
        state.selectedAgentProfileRevisionId = 7

        _ = try await service.sendMessage("hello", state: state)

        #expect(coordinator.agentProfileRevisionIds == [7])
    }

    @Test("coordinator paused run is not marked completed")
    @MainActor
    func coordinatorPausedRunIsNotMarkedCompleted() async throws {
        let coordinator = RecordingChatInteractionCoordinator(eventsToEmit: [
            event(
                id: "tool_call_entry",
                kind: .toolCallRequested,
                payload: #"{"tool_call_id":"call_1","tool_name":"debug.echo"}"#
            ),
            event(
                id: "waiting",
                kind: .runWaitingTool,
                payload: "run.waiting_tool"
            ),
        ], result: ChatInteractionResult(runId: "run_1", state: .waitingTool))
        let service = AgentRuntimeService(
            runtimeClient: ScriptedRuntimeClient(),
            toolDriver: MinimalHostToolDriver(),
            coordinator: coordinator
        )

        let state = try await service.sendMessage(
            "use tool debug.echo",
            state: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        #expect(state.phase == .running(runId: "run_1"))
        #expect(state.lastTerminalReason == Optional<RunTerminalReason>.none)
    }

    @Test("select conversation can load explicit branch leaf events")
    func selectConversationCanLoadExplicitBranchLeafEvents() async throws {
        let client = ScriptedRuntimeClient()
        await client.setActiveBranchForTest(
            sessionId: "session_2",
            leafId: "leaf_2",
            events: [
                event(id: "user_2", sessionId: "session_2", kind: .userMessage, payload: "hi", runId: "run_2"),
                event(
                    id: "assistant_2",
                    sessionId: "session_2",
                    kind: .assistantMessageCompleted,
                    payload: "there",
                    runId: "run_2"
                ),
            ]
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.selectConversation(
            sessionId: "session_2",
            leafId: "leaf_2",
            state: AgentViewState(
                phase: .ready,
                messages: [AgentMessageViewState(id: "old", role: .user, text: "old", isStreaming: false)],
                currentSessionId: "session_1"
            )
        )

        #expect(await client.activeBranchRequests == [
            ScriptedRuntimeClient.ActiveBranchRequest(sessionId: "session_2", leafId: "leaf_2"),
        ])
        #expect(state.currentSessionId == "session_2")
        #expect(state.messages.map(\.text) == ["hi", "there"])
    }

    @Test("fork conversation creates a new chat from the selected branch leaf")
    func forkConversationCreatesNewChatFromSelectedBranchLeaf() async throws {
        let client = ScriptedRuntimeClient()
        await client.setForkSessionResultForTest("session_2")
        await client.setActiveBranchForTest(
            sessionId: "session_2",
            leafId: nil,
            events: [
                event(id: "user_2", sessionId: "session_2", kind: .userMessage, payload: "hi", runId: "run_2"),
                event(
                    id: "assistant_2",
                    sessionId: "session_2",
                    kind: .assistantMessageCompleted,
                    payload: "there",
                    runId: "run_2"
                ),
            ]
        )
        await client.setConversationSummariesForTest([
            ConversationSummaryDTO(
                sessionId: "session_2",
                title: "hi",
                activeLeafId: "assistant_2",
                lastEventId: "assistant_2",
                lastUpdatedSequence: 8
            ),
            ConversationSummaryDTO(
                sessionId: "session_1",
                title: "old",
                activeLeafId: "assistant_1",
                lastEventId: "assistant_1",
                lastUpdatedSequence: 4
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = AgentViewState(
            phase: .ready,
            messages: [AgentMessageViewState(id: "old", role: .user, text: "old", isStreaming: false)],
            currentSessionId: "session_1"
        )

        let nextState = try await service.forkConversation(
            sessionId: "session_1",
            leafId: "assistant_1",
            state: state
        )

        #expect(await client.forkSessionRequests == [
            ScriptedRuntimeClient.ForkSessionRequest(sessionId: "session_1", leafId: "assistant_1"),
        ])
        #expect(await client.activeBranchRequests == [
            ScriptedRuntimeClient.ActiveBranchRequest(sessionId: "session_2", leafId: nil),
        ])
        #expect(nextState.currentSessionId == "session_2")
        #expect(nextState.messages.map(\.text) == ["hi", "there"])
        #expect(nextState.conversations.conversations.map(\.sessionId) == ["session_2", "session_1"])
    }

    @Test("select conversation restores attachment blob refs")
    func selectConversationRestoresAttachmentBlobRefs() async throws {
        let client = ScriptedRuntimeClient()
        let blobRefs = RuntimeBlobRefCodec.encodeUserMessage(
            text: "hi",
            attachments: [
                AttachmentDraftViewState(
                    id: "link_1",
                    kind: .link,
                    displayName: "example.com",
                    localPath: nil,
                    urlString: "https://example.com",
                    mimeType: nil,
                    byteCount: nil
                ),
            ]
        )
        await client.setActiveBranchForTest(
            sessionId: "session_2",
            leafId: nil,
            events: [
                event(
                    id: "user_2",
                    sessionId: "session_2",
                    kind: .userMessage,
                    payload: "hi\nLink: https://example.com",
                    runId: "run_2",
                    blobRefs: blobRefs
                ),
            ]
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.selectConversation(
            sessionId: "session_2",
            state: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        #expect(state.messages.map(\.text) == ["hi"])
        #expect(state.messages[0].attachments.map(\.urlString) == ["https://example.com"])
    }

    @Test("archive active conversation hides it and clears the active chat")
    func archiveActiveConversationHidesItAndClearsActiveChat() async throws {
        let client = ScriptedRuntimeClient()
        await client.setConversationSummariesForTest([])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = AgentViewState(
            phase: .ready,
            messages: [AgentMessageViewState(id: "old", role: .user, text: "old", isStreaming: false)],
            currentSessionId: "session_1",
            conversations: ConversationListViewState(conversations: [
                ConversationSummaryViewState(
                    sessionId: "session_1",
                    title: "Old",
                    activeLeafId: "leaf_1",
                    lastEventId: "leaf_1",
                    lastUpdatedSequence: 1
                ),
            ])
        )

        let nextState = try await service.archiveConversation(sessionId: "session_1", state: state)

        #expect(await client.archivedSessionIds == ["session_1"])
        #expect(nextState.currentSessionId == nil)
        #expect(nextState.messages.isEmpty)
        #expect(nextState.conversations.conversations.isEmpty)
    }

    @Test("delete active conversation removes it and clears the active chat")
    func deleteActiveConversationRemovesItAndClearsActiveChat() async throws {
        let client = ScriptedRuntimeClient()
        await client.setConversationSummariesForTest([])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = AgentViewState(
            phase: .ready,
            messages: [AgentMessageViewState(id: "old", role: .user, text: "old", isStreaming: false)],
            currentSessionId: "session_1",
            conversations: ConversationListViewState(conversations: [
                ConversationSummaryViewState(
                    sessionId: "session_1",
                    title: "Old",
                    activeLeafId: "leaf_1",
                    lastEventId: "leaf_1",
                    lastUpdatedSequence: 1
                ),
            ])
        )

        let nextState = try await service.deleteConversation(sessionId: "session_1", state: state)

        #expect(await client.deletedSessionIds == ["session_1"])
        #expect(nextState.currentSessionId == nil)
        #expect(nextState.messages.isEmpty)
        #expect(nextState.conversations.conversations.isEmpty)
    }

    @Test("send applies completed mock chat events")
    func sendAppliesCompletedMockChatEvents() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_1", kind: .userMessage, payload: "hello"),
                    event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                    event(id: "delta_1", kind: .assistantTextDelta, payload: "Mock "),
                    event(id: "delta_2", kind: .assistantTextDelta, payload: "response to: hello"),
                    event(id: "completed", kind: .assistantMessageCompleted, payload: "Mock response to: hello"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state = try await service.sendMessage("hello", state: state)

        #expect(await client.sentMessages.map(\.text) == ["hello"])
        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text) == ["hello", "Mock response to: hello"])
    }

    @Test("send uses draft target parent event id for forked turns")
    func sendUsesDraftTargetParentEventIdForForkedTurns() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_1", kind: .userMessage, payload: "forked"),
                    event(id: "assistant_1", kind: .assistantMessageCompleted, payload: "branched"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state.draft.targetParentEventId = "entry_4"
        state = try await service.sendMessage("forked", state: state)

        #expect(await client.sentMessages.map(\.parentEventId) == ["entry_4"])
        #expect(state.draft.targetParentEventId == nil)
    }

    @Test("send includes draft link attachments in prompt and visible message")
    func sendIncludesDraftLinkAttachmentsInPromptAndVisibleMessage() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_1", kind: .userMessage, payload: "hello\nLink: https://example.com"),
                    event(id: "assistant_1", kind: .assistantMessageCompleted, payload: "linked"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state.draft.text = "hello"
        state.draft.attachments = [
            AttachmentDraftViewState(
                id: "link_1",
                kind: .link,
                displayName: "example.com",
                localPath: nil,
                urlString: "https://example.com",
                mimeType: nil,
                byteCount: nil
            ),
        ]
        state = try await service.sendMessage("hello", state: state)

        let sentMessages = await client.sentMessages
        #expect(sentMessages.map(\.text) == ["hello\nLink: https://example.com"])
        #expect(RuntimeBlobRefCodec.decodeUserMessage(from: sentMessages[0].blobRefs).text == "hello")
        #expect(RuntimeBlobRefCodec.decodeUserMessage(from: sentMessages[0].blobRefs).attachments.map(\.urlString) == ["https://example.com"])
        #expect(state.messages[0].text == "hello")
        #expect(state.messages[0].attachments.count == 1)
        #expect(state.messages[0].attachments[0].kind == .link)
        #expect(state.messages[0].attachments[0].urlString == "https://example.com")
        #expect(state.draft.text.isEmpty)
        #expect(state.draft.attachments.isEmpty)
    }

    @Test("send includes draft image metadata in prompt and visible message")
    func sendIncludesDraftImageMetadataInPromptAndVisibleMessage() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(
                        id: "user_1",
                        kind: .userMessage,
                        payload: "look\nImage attached: photo.png"
                    ),
                    event(id: "assistant_1", kind: .assistantMessageCompleted, payload: "image noted"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state.draft.text = "look"
        state.draft.attachments = [
            AttachmentDraftViewState(
                id: "image_1",
                kind: .image,
                displayName: "photo.png",
                localPath: "/tmp/photo.png",
                urlString: nil,
                mimeType: "image/png",
                byteCount: 3,
                imageWidth: 1,
                imageHeight: 2,
                rgbDataBase64: "AQIDBAUG"
            ),
        ]
        state = try await service.sendMessage("look", state: state)

        let sentMessages = await client.sentMessages
        #expect(sentMessages.map(\.text) == [
            "look\nImage attached: photo.png",
        ])
        let decoded = RuntimeBlobRefCodec.decodeUserMessage(from: sentMessages[0].blobRefs)
        #expect(decoded.text == "look")
        #expect(decoded.attachments.map(\.localPath) == ["/tmp/photo.png"])
        #expect(decoded.attachments.map(\.imageWidth) == [1])
        #expect(decoded.attachments.map(\.imageHeight) == [2])
        #expect(decoded.attachments.map(\.rgbDataBase64) == ["AQIDBAUG"])
        #expect(state.messages[0].text == "look")
        #expect(state.messages[0].attachments.count == 1)
        #expect(state.messages[0].attachments[0].kind == .image)
        #expect(state.messages[0].attachments[0].localPath == "/tmp/photo.png")
        #expect(state.draft.text.isEmpty)
    }

    @Test("send includes draft file contents in prompt and visible message")
    func sendIncludesDraftFileContentsInPromptAndVisibleMessage() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(
                        id: "user_1",
                        kind: .userMessage,
                        payload: "summarize\nFile attached: notes.txt\nFile contents:\nTrip plan"
                    ),
                    event(id: "assistant_1", kind: .assistantMessageCompleted, payload: "noted"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state.draft.text = "summarize"
        state.draft.attachments = [
            AttachmentDraftViewState(
                id: "file_1",
                kind: .file,
                displayName: "notes.txt",
                localPath: "/tmp/notes.txt",
                urlString: nil,
                mimeType: "text/plain",
                byteCount: 9,
                textContent: "Trip plan"
            ),
        ]
        state = try await service.sendMessage("summarize", state: state)

        let sentMessages = await client.sentMessages
        #expect(sentMessages.map(\.text) == [
            "summarize\nFile attached: notes.txt\nFile contents:\nTrip plan",
        ])
        let decoded = RuntimeBlobRefCodec.decodeUserMessage(from: sentMessages[0].blobRefs)
        #expect(decoded.text == "summarize")
        #expect(decoded.attachments.map(\.kind) == [.file])
        #expect(decoded.attachments.map(\.localPath) == ["/tmp/notes.txt"])
        #expect(decoded.attachments.map(\.textContent) == ["Trip plan"])
        #expect(state.messages[0].text == "summarize")
        #expect(state.messages[0].attachments.count == 1)
        #expect(state.messages[0].attachments[0].kind == .file)
        #expect(state.messages[0].attachments[0].displayName == "notes.txt")
        #expect(state.draft.text.isEmpty)
        #expect(state.draft.attachments.isEmpty)
    }

    @Test("regenerate root response resends original user message from root")
    func regenerateRootResponseResendsOriginalUserMessageFromRoot() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_regen", kind: .userMessage, payload: "hello"),
                    event(id: "assistant_regen", kind: .assistantMessageCompleted, payload: "new answer"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = AgentViewState(
            phase: .ready,
            messages: [
                AgentMessageViewState(
                    id: "user_1",
                    sessionId: "session_1",
                    parentId: nil,
                    role: .user,
                    parts: [.text(TextPartViewState(id: "user_text", text: "hello"))]
                ),
                AgentMessageViewState(
                    id: "assistant_1",
                    sessionId: "session_1",
                    parentId: "user_1",
                    role: .assistant,
                    parts: [.text(TextPartViewState(id: "assistant_text", text: "old answer"))]
                ),
            ],
            currentSessionId: "session_1"
        )

        _ = try await service.regenerate(from: "assistant_1", state: state)

        #expect(await client.sentMessages.map(\.text) == ["hello"])
        #expect(await client.sentMessages.map(\.parentEventId) == ["__local_agent_root__"])
    }

    @Test("edit and resend replaces the visible branch with edited text")
    func editAndResendReplacesVisibleBranchWithEditedText() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    event(id: "user_edited", kind: .userMessage, payload: "edited prompt"),
                    event(id: "assistant_edited", kind: .assistantMessageCompleted, payload: "edited answer"),
                ],
                pendingToolCallId: nil
            ),
        ])
        await client.setActiveBranchForTest(
            sessionId: "session_1",
            leafId: nil,
            events: [
                event(
                    id: "user_edited",
                    sessionId: "session_1",
                    parentId: "root_event",
                    kind: .userMessage,
                    payload: "edited prompt",
                    runId: "run_1"
                ),
                event(
                    id: "assistant_edited",
                    sessionId: "session_1",
                    parentId: "user_edited",
                    kind: .assistantMessageCompleted,
                    payload: "edited answer",
                    runId: "run_1"
                ),
            ]
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = AgentViewState(
            phase: .ready,
            messages: [
                AgentMessageViewState(
                    id: "user_1",
                    sessionId: "session_1",
                    parentId: "root_event",
                    role: .user,
                    parts: [.text(TextPartViewState(id: "user_text", text: "original prompt"))]
                ),
            ],
            currentSessionId: "session_1"
        )

        let nextState = try await service.editAndResend(messageId: "user_1", text: "edited prompt", state: state)

        #expect(await client.sentMessages.map(\.text) == ["edited prompt"])
        #expect(await client.sentMessages.map(\.parentEventId) == ["root_event"])
        #expect(await client.activeBranchRequests == [
            ScriptedRuntimeClient.ActiveBranchRequest(sessionId: "session_1", leafId: nil),
        ])
        #expect(nextState.messages.map(\.text) == ["edited prompt", "edited answer"])
    }

    @Test("streamed delta is delivered before final turn result")
    func streamedDeltaIsDeliveredBeforeFinalTurnResult() async throws {
        let client = StreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let observation = StreamObservation()

        let prepared = try await service.prepare()
        async let finalState = service.sendMessage("hello", state: prepared) { event in
            if event.kind == .assistantTextDelta {
                await observation.observeDelta()
            }
        }

        await observation.waitForDelta()
        #expect(await client.didReleaseFinalResult == false)

        await client.releaseFinalResult()
        let state = try await finalState

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text) == ["hello", "hello world"])
    }

    @Test("buffered structured delta is delivered before another stream event arrives")
    func bufferedStructuredDeltaIsDeliveredBeforeAnotherStreamEventArrives() async throws {
        let client = BufferedStreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let observation = StreamObservation()

        let prepared = try await service.prepare()
        async let finalState = service.sendMessage("hello", state: prepared) { event in
            if event.kind == .assistantTextDelta {
                await observation.observeDelta()
            }
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await observation.didObserveDeltaValue)
        #expect(await client.didReleaseFinalResult == false)

        await client.releaseFinalResult()
        let state = try await finalState

        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text) == ["hello", "hello world"])
    }

    @Test("structured stream deltas are coalesced before final turn replay")
    func structuredStreamDeltasAreCoalescedBeforeFinalTurnReplay() async throws {
        let client = CoalescingStreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let recorder = StreamEventRecorder()

        let prepared = try await service.prepare()
        let state = try await service.sendMessage("hello", state: prepared) { event in
            await recorder.record(event)
        }

        let observedEvents = await recorder.events
        let observedDeltas = observedEvents.filter { $0.kind == .assistantTextDelta }
        let payload = try #require(observedDeltas.first?.payload)
        let payloadObject = try #require(jsonObject(from: payload))

        #expect(observedDeltas.count == 1)
        #expect(payloadObject["message_id"] == "assistant_1")
        #expect(payloadObject["text"] == "Hello")
        #expect(state.messages.count == 2)
        #expect(state.messages.map(\.text) == ["hello", "Hello!"])
        #expect(state.lastTerminalReason == .completed)
    }

    @Test("failed stream result marks partial output failed without terminal event")
    func failedStreamResultMarksPartialOutputFailedWithoutTerminalEvent() async throws {
        let client = TerminalResultStreamingRuntimeClientProbe(resultState: .failed)
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let prepared = try await service.prepare()
        let state = try await service.sendMessage("hello", state: prepared)

        #expect(state.phase == .failed(message: "Run failed."))
        #expect(state.errorMessage == "Run failed.")
        #expect(state.lastTerminalReason == .failed("Run failed."))
        #expect(state.messages.map(\.text) == ["hello", "partial"])
        #expect(state.messages[1].streaming == .failed("Run failed."))
    }

    @Test("cancelled stream result marks partial output cancelled without terminal event")
    func cancelledStreamResultMarksPartialOutputCancelledWithoutTerminalEvent() async throws {
        let client = TerminalResultStreamingRuntimeClientProbe(resultState: .cancelled)
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let prepared = try await service.prepare()
        let state = try await service.sendMessage("hello", state: prepared)

        #expect(state.phase == .ready)
        #expect(state.lastTerminalReason == .cancelled)
        #expect(state.messages.map(\.text) == ["hello", "partial"])
        #expect(state.messages[1].streaming == .cancelled)
    }

    @Test("stream event failure flushes buffered partial output before throwing")
    func streamEventFailureFlushesBufferedPartialOutputBeforeThrowing() async throws {
        let client = ThrowingStreamingRuntimeClientProbe()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let recorder = StreamEventRecorder()

        let prepared = try await service.prepare()
        do {
            _ = try await service.sendMessage("hello", state: prepared) { event in
                await recorder.record(event)
            }
            Issue.record("Expected stream failure")
        } catch is RuntimeStreamProbeError {
        }

        let observedEvents = await recorder.events
        let observedDeltas = observedEvents.filter { $0.kind == .assistantTextDelta }
        let payload = try #require(observedDeltas.first?.payload)
        let payloadObject = try #require(jsonObject(from: payload))
        #expect(observedDeltas.count == 1)
        #expect(payloadObject["text"] == "partial")
    }

    @Test("second send is rejected while first send is still in flight")
    func secondSendIsRejectedWhileFirstSendIsInFlight() async throws {
        let client = BlockingSendRuntimeClient()
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())
        let state = try await service.prepare()

        async let firstSend = service.sendMessage("first", state: state)
        await client.waitForSendStarted()

        do {
            _ = try await service.sendMessage("second", state: state)
            Issue.record("Expected duplicate run rejection")
        } catch let error as AgentRuntimeServiceError {
            #expect(error == .duplicateRun)
        }

        await client.completeSend(with: AgentTurnResultDTO(
            runId: "run_1",
            state: .completed,
            events: [
                event(id: "user_1", kind: .userMessage, payload: "first"),
                event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                event(id: "completed", kind: .assistantMessageCompleted, payload: "Mock response to: first"),
            ],
            pendingToolCallId: nil
        ))
        _ = try await firstSend

        #expect(await client.sentMessages.map(\.text) == ["first"])
    }

    @Test("failed tool continuation releases active run guard")
    func failedToolContinuationReleasesActiveRunGuard() async throws {
        let client = ScriptedRuntimeClient(sendTurns: [
            AgentTurnResultDTO(
                runId: "run_1",
                state: .waitingTool,
                events: [
                    event(id: "user_1", kind: .userMessage, payload: "use tool debug.echo"),
                    event(
                        id: "tool_call",
                        kind: .toolCallRequested,
                        payload: #"{"call_id":"call_missing","name":"debug.echo","arguments_json":"{\"text\":\"hello\"}","route_state":"ready","route_reason":null}"#
                    ),
                ],
                pendingToolCallId: "call_missing"
            ),
            AgentTurnResultDTO(
                runId: "run_2",
                state: .completed,
                events: [
                    event(id: "user_2", kind: .userMessage, payload: "hello", runId: "run_2"),
                    event(id: "assistant_started_2", kind: .assistantMessageStarted, payload: "run run_2", runId: "run_2"),
                    event(id: "completed_2", kind: .assistantMessageCompleted, payload: "Mock response to: hello", runId: "run_2"),
                ],
                pendingToolCallId: nil
            ),
        ])
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        let state = try await service.prepare()
        do {
            _ = try await service.sendMessage("use tool debug.echo", state: state)
            Issue.record("Expected missing pending tool request")
        } catch let error as AgentRuntimeServiceError {
            #expect(error == .missingPendingToolRequest("call_missing"))
        }

        let recovered = try await service.sendMessage("hello", state: state)
        #expect(recovered.phase == .ready)
        #expect(recovered.messages.map(\.text).contains("Mock response to: hello"))
    }

    @Test("waiting tool turn is executed and submitted once")
    func waitingToolTurnIsExecutedAndSubmittedOnce() async throws {
        let client = ScriptedRuntimeClient(
            sendTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .waitingTool,
                    events: [
                        event(id: "user_1", kind: .userMessage, payload: "use tool debug.echo"),
                        event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                        event(
                            id: "tool_call",
                            kind: .toolCallRequested,
                            payload: #"{"call_id":"call_1","name":"debug.echo","arguments_json":"{\"text\":\"hello\"}","route_state":"ready","route_reason":null}"#
                        ),
                    ],
                    pendingToolCallId: "call_1"
                ),
            ],
            submitTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .completed,
                    events: [
                        event(
                            id: "tool_result",
                            kind: .toolResultMessage,
                            payload: #"{"type":"tool_result","display_text":"Echo: hello","model_text":"debug.echo: hello","structured_json":"{\"text\":\"hello\"}","audit_text":"debug.echo executed","sensitivity":"public","retention":"run_only","is_error":false}"#
                        ),
                        event(id: "delta_1", kind: .assistantTextDelta, payload: "Mock response "),
                        event(id: "delta_2", kind: .assistantTextDelta, payload: "after tool: debug.echo: hello"),
                        event(
                            id: "completed",
                            kind: .assistantMessageCompleted,
                            payload: "Mock response after tool: debug.echo: hello"
                        ),
                    ],
                    pendingToolCallId: nil
                ),
            ],
            pendingToolRequests: [
                ToolExecutionRequestDTO(
                    runId: "run_1",
                    sessionId: "session_1",
                    toolCallEntryId: "tool_call",
                    toolCallId: "call_1",
                    toolName: "debug.echo",
                    argumentsJson: #"{"text":"hello"}"#
                ),
            ]
        )
        let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

        var state = try await service.prepare()
        state = try await service.sendMessage("use tool debug.echo", state: state)

        #expect(await client.submittedToolResults.count == 1)
        #expect(await client.submittedToolResults.first?.result.modelText == "debug.echo: hello")
        #expect(state.messages.map(\.text).contains("Echo: hello"))
        #expect(state.messages.map(\.text).contains("Mock response after tool: debug.echo: hello"))
    }

    @Test("continuation limit submits an error tool result to finish the run")
    func continuationLimitSubmitsErrorToolResultToFinishRun() async throws {
        let client = ScriptedRuntimeClient(
            sendTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .waitingTool,
                    events: [
                        event(id: "user_1", kind: .userMessage, payload: "use tool debug.echo"),
                        event(
                            id: "tool_call",
                            kind: .toolCallRequested,
                            payload: #"{"call_id":"call_1","name":"debug.echo","arguments_json":"{\"text\":\"hello\"}","route_state":"ready","route_reason":null}"#
                        ),
                    ],
                    pendingToolCallId: "call_1"
                ),
            ],
            submitTurns: [
                AgentTurnResultDTO(
                    runId: "run_1",
                    state: .completed,
                    events: [
                        event(
                            id: "tool_result",
                            kind: .toolResultMessage,
                            payload: #"{"type":"tool_result","display_text":"Tool stopped: continuation limit exceeded.","model_text":"debug.echo stopped: continuation limit exceeded.","structured_json":"{\"error\":\"continuation_limit_exceeded\",\"tool_name\":\"debug.echo\"}","audit_text":"Stopped debug.echo: continuation limit exceeded.","sensitivity":"public","retention":"run_only","is_error":true}"#
                        ),
                        event(
                            id: "completed",
                            kind: .assistantMessageCompleted,
                            payload: "Mock response after tool: debug.echo stopped: continuation limit exceeded."
                        ),
                    ],
                    pendingToolCallId: nil
                ),
            ],
            pendingToolRequests: [
                ToolExecutionRequestDTO(
                    runId: "run_1",
                    sessionId: "session_1",
                    toolCallEntryId: "tool_call",
                    toolCallId: "call_1",
                    toolName: "debug.echo",
                    argumentsJson: #"{"text":"hello"}"#
                ),
            ]
        )
        let service = AgentRuntimeService(
            runtimeClient: client,
            toolDriver: MinimalHostToolDriver(maxContinuations: 0)
        )

        var state = try await service.prepare()
        state = try await service.sendMessage("use tool debug.echo", state: state)

        #expect(await client.submittedToolResults.count == 1)
        #expect(await client.submittedToolResults.first?.result.isError == true)
        #expect(await client.submittedToolResults.first?.result.structuredJson.contains("continuation_limit_exceeded") == true)
        #expect(state.phase == .ready)
        #expect(state.messages.map(\.text).contains("Tool stopped: continuation limit exceeded."))
    }

    private func event(
        id: String,
        sessionId: String = "session_1",
        parentId: String? = nil,
        kind: RuntimeEventKindDTO,
        payload: String,
        runId: String = "run_1",
        blobRefs: [String] = []
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: sessionId,
            parentId: parentId,
            runId: runId,
            sequence: 0,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: blobRefs
        )
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

private actor StreamObservation {
    private var didObserveDelta = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var didObserveDeltaValue: Bool {
        didObserveDelta
    }

    func observeDelta() {
        didObserveDelta = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func waitForDelta() async {
        if didObserveDelta {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor StreamEventRecorder {
    private(set) var events: [RuntimeEventDTO] = []

    func record(_ event: RuntimeEventDTO) {
        events.append(event)
    }
}

private actor StreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0
    private var finalResultContinuation: CheckedContinuation<Void, Never>?
    private var releasedFinalResult = false

    var didReleaseFinalResult: Bool {
        releasedFinalResult
    }

    func releaseFinalResult() {
        releasedFinalResult = true
        finalResultContinuation?.resume()
        finalResultContinuation = nil
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task<AgentTurnResultDTO, any Error> {
            continuation.yield(Self.event(id: "user_1", kind: .userMessage, payload: text))
            continuation.yield(Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"))
            continuation.yield(Self.event(id: "delta_1", kind: .assistantTextDelta, payload: "hello "))
            await self.waitForFinalRelease()
            continuation.yield(Self.event(id: "completed", kind: .assistantMessageCompleted, payload: "hello world"))
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    Self.event(id: "user_1", kind: .userMessage, payload: text),
                    Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: "run run_1"),
                    Self.event(id: "delta_1", kind: .assistantTextDelta, payload: "hello "),
                    Self.event(id: "completed", kind: .assistantMessageCompleted, payload: "hello world"),
                ],
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private func waitForFinalRelease() async {
        if releasedFinalResult {
            return
        }
        await withCheckedContinuation { continuation in
            finalResultContinuation = continuation
        }
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 0,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor BufferedStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0
    private var finalResultContinuation: CheckedContinuation<Void, Never>?
    private var releasedFinalResult = false

    var didReleaseFinalResult: Bool {
        releasedFinalResult
    }

    func releaseFinalResult() {
        releasedFinalResult = true
        finalResultContinuation?.resume()
        finalResultContinuation = nil
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task<AgentTurnResultDTO, any Error> {
            continuation.yield(Self.event(id: "user_1", kind: .userMessage, payload: text))
            continuation.yield(Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#))
            continuation.yield(Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"hello "}"#))
            await self.waitForFinalRelease()
            continuation.yield(Self.event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"hello world"}"#))
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: [
                    Self.event(id: "user_1", kind: .userMessage, payload: text),
                    Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
                    Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"hello "}"#),
                    Self.event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"hello world"}"#),
                ],
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private func waitForFinalRelease() async {
        if releasedFinalResult {
            return
        }
        await withCheckedContinuation { continuation in
            finalResultContinuation = continuation
        }
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 0,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor CoalescingStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let streamedEvents = [
            Self.event(id: "user_1", kind: .userMessage, payload: text),
            Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"Hel"}"#),
            Self.event(id: "delta_2", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"lo"}"#),
            Self.event(id: "completed", kind: .assistantMessageCompleted, payload: #"{"message_id":"assistant_1","text":"Hello!"}"#),
        ]
        let result = Task<AgentTurnResultDTO, any Error> {
            for event in streamedEvents {
                continuation.yield(event)
            }
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: .completed,
                events: streamedEvents,
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 0,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor TerminalResultStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private let resultState: RunStateDTO
    private var sessionCount = 0

    init(resultState: RunStateDTO) {
        self.resultState = resultState
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let streamedEvents = [
            Self.event(id: "user_1", kind: .userMessage, payload: text),
            Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#),
            Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"partial"}"#),
        ]
        let state = resultState
        let result = Task<AgentTurnResultDTO, any Error> {
            for event in streamedEvents {
                continuation.yield(event)
            }
            continuation.finish()
            return AgentTurnResultDTO(
                runId: "run_1",
                state: state,
                events: streamedEvents,
                pendingToolCallId: nil
            )
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 0,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private enum RuntimeStreamProbeError: Error {
    case streamStopped
}

private actor ThrowingStreamingRuntimeClientProbe: StreamingRuntimeClient {
    private var sessionCount = 0

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        fatalError("streaming service path must call sendMessageStream")
    }

    nonisolated func sendMessageStream(
        sessionId: String,
        parentEventId: String?,
        text: String
    ) -> AgentTurnStreamDTO {
        let (events, continuation) = AsyncThrowingStream.makeStream(
            of: RuntimeEventDTO.self,
            throwing: Error.self
        )
        let result = Task<AgentTurnResultDTO, any Error> {
            continuation.yield(Self.event(id: "user_1", kind: .userMessage, payload: text))
            continuation.yield(Self.event(id: "assistant_started", kind: .assistantMessageStarted, payload: #"{"message_id":"assistant_1"}"#))
            continuation.yield(Self.event(id: "delta_1", kind: .assistantTextDelta, payload: #"{"message_id":"assistant_1","text":"partial"}"#))
            continuation.finish(throwing: RuntimeStreamProbeError.streamStopped)
            throw RuntimeStreamProbeError.streamStopped
        }
        return AgentTurnStreamDTO(events: events, result: result)
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        fatalError("no tool continuation expected")
    }

    nonisolated func submitToolResultStream(
        runId: String,
        result: ToolResultDTO
    ) -> AgentTurnStreamDTO {
        fatalError("no tool continuation expected")
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        fatalError("no approval expected")
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        Self.event(id: "cancelled", kind: .runCancelled, payload: "cancelled")
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    private static func event(
        id: String,
        kind: RuntimeEventKindDTO,
        payload: String
    ) -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: id,
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 0,
            depth: 0,
            kind: kind,
            payload: payload,
            blobRefs: []
        )
    }
}

private actor BlockingSendRuntimeClient: RuntimeClient {
    private var sendContinuation: CheckedContinuation<AgentTurnResultDTO, Never>?
    private var sendStartedContinuation: CheckedContinuation<Void, Never>?

    private(set) var sentMessages: [ScriptedRuntimeClient.SentMessage] = []

    func waitForSendStarted() async {
        if !sentMessages.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            sendStartedContinuation = continuation
        }
    }

    func completeSend(with turn: AgentTurnResultDTO) {
        sendContinuation?.resume(returning: turn)
        sendContinuation = nil
    }

    func createSession() async throws -> String {
        "session_1"
    }

    func sessionIds() async throws -> [String] {
        ["session_1"]
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {}
    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        sentMessages.append(ScriptedRuntimeClient.SentMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text
        ))
        sendStartedContinuation?.resume()
        sendStartedContinuation = nil
        return await withCheckedContinuation { continuation in
            sendContinuation = continuation
        }
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        []
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        AgentTurnResultDTO(runId: runId, state: .completed, events: [], pendingToolCallId: nil)
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        AgentTurnResultDTO(runId: "run_1", state: .completed, events: [], pendingToolCallId: nil)
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: "cancelled",
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: 0,
            depth: 0,
            kind: .runCancelled,
            payload: "cancelled",
            blobRefs: []
        )
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }
}

private actor ScriptedRuntimeClient: BlobReferencingRuntimeClient, ProviderControllingRuntimeClient, RuntimeOptionsControllingRuntimeClient, ConversationRuntimeClient {
    struct SentMessage: Equatable, Sendable {
        var sessionId: String
        var parentEventId: String?
        var text: String
        var blobRefs: [String] = []
    }

    struct SubmittedToolResult: Sendable {
        var runId: String
        var result: ToolResultDTO
    }

    struct SelectedProvider: Equatable, Sendable {
        var sessionId: String
        var providerId: String
    }

    struct ActiveBranchRequest: Equatable, Sendable {
        var sessionId: String
        var leafId: String?
    }

    struct ForkSessionRequest: Equatable, Sendable {
        var sessionId: String
        var leafId: String
    }

    struct RenamedSession: Equatable, Sendable {
        var sessionId: String
        var title: String
    }

    struct RuntimeOptionsSubmission: Equatable, Sendable {
        var systemPrompt: String
        var runtimePolicy: String
        var temperature: Double?
        var topP: Double?
    }

    private var sessionCount = 0
    private var sendTurns: [AgentTurnResultDTO]
    private var submitTurns: [AgentTurnResultDTO]
    private var pendingRequests: [ToolExecutionRequestDTO]
    private var providerProfilesForTest: [ProviderProfileDTO]
    private var activeProviderForTest: ProviderProfileDTO
    private var conversationSummariesForTest: [ConversationSummaryDTO] = []
    private var activeBranchEventsForTest: [String: [RuntimeEventDTO]] = [:]
    private var forkSessionResultForTest = "session_forked"

    private(set) var registeredToolSchemas: [ToolSchemaDTO] = []
    private(set) var sentMessages: [SentMessage] = []
    private(set) var submittedToolResults: [SubmittedToolResult] = []
    private(set) var selectedProviders: [SelectedProvider] = []
    private(set) var activeBranchRequests: [ActiveBranchRequest] = []
    private(set) var forkSessionRequests: [ForkSessionRequest] = []
    private(set) var renamedSessions: [RenamedSession] = []
    private(set) var runtimeOptions: [RuntimeOptionsSubmission] = []
    private(set) var archivedSessionIds: [String] = []
    private(set) var deletedSessionIds: [String] = []

    init(
        sendTurns: [AgentTurnResultDTO] = [],
        submitTurns: [AgentTurnResultDTO] = [],
        pendingToolRequests: [ToolExecutionRequestDTO] = []
    ) {
        self.sendTurns = sendTurns
        self.submitTurns = submitTurns
        self.pendingRequests = pendingToolRequests
        self.providerProfilesForTest = [
            ProviderProfileDTO(
                id: "mock",
                displayName: "Mock",
                kind: .mock,
                maxContextTokens: 100
            ),
        ]
        self.activeProviderForTest = providerProfilesForTest[0]
    }

    func setProviderProfilesForTest(_ profiles: [ProviderProfileDTO]) {
        providerProfilesForTest = profiles
        if activeProviderForTest.id.isEmpty || !profiles.contains(where: { $0.id == activeProviderForTest.id }) {
            activeProviderForTest = profiles[0]
        }
    }

    func setActiveProviderForTest(_ profile: ProviderProfileDTO) {
        activeProviderForTest = profile
    }

    func setConversationSummariesForTest(_ summaries: [ConversationSummaryDTO]) {
        conversationSummariesForTest = summaries
    }

    func setActiveBranchForTest(
        sessionId: String,
        leafId: String?,
        events: [RuntimeEventDTO]
    ) {
        activeBranchEventsForTest[activeBranchKey(sessionId: sessionId, leafId: leafId)] = events
    }

    func setForkSessionResultForTest(_ sessionId: String) {
        forkSessionResultForTest = sessionId
    }

    func createSession() async throws -> String {
        sessionCount += 1
        return "session_\(sessionCount)"
    }

    func sessionIds() async throws -> [String] {
        guard sessionCount > 0 else {
            return []
        }
        return (1...sessionCount).map { "session_\($0)" }
    }

    func registerToolSchema(_ schema: ToolSchemaDTO) async throws {
        registeredToolSchemas.append(schema)
    }

    func setPermissionState(scope: String, state: PermissionStateDTO) async throws {}

    func sendMessage(sessionId: String, parentEventId: String?, text: String) async throws -> AgentTurnResultDTO {
        try await sendMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text,
            blobRefs: []
        )
    }

    func sendMessage(
        sessionId: String,
        parentEventId: String?,
        text: String,
        blobRefs: [String]
    ) async throws -> AgentTurnResultDTO {
        sentMessages.append(SentMessage(
            sessionId: sessionId,
            parentEventId: parentEventId,
            text: text,
            blobRefs: blobRefs
        ))
        return sendTurns.removeFirst()
    }

    func pendingToolRequests() async throws -> [ToolExecutionRequestDTO] {
        pendingRequests
    }

    func pendingApprovalRequests() async throws -> [ApprovalProtocolRequestDTO] {
        []
    }

    func submitToolResult(runId: String, result: ToolResultDTO) async throws -> AgentTurnResultDTO {
        submittedToolResults.append(SubmittedToolResult(runId: runId, result: result))
        pendingRequests.removeAll { $0.runId == runId }
        return submitTurns.removeFirst()
    }

    func submitApprovalResponse(_ response: ApprovalProtocolResponseDTO) async throws -> AgentTurnResultDTO {
        submitTurns.removeFirst()
    }

    func cancel(runId: String) async throws -> RuntimeEventDTO {
        RuntimeEventDTO(
            id: "cancelled",
            sessionId: "session_1",
            parentId: nil,
            runId: runId,
            sequence: 0,
            depth: 0,
            kind: .runCancelled,
            payload: "cancelled",
            blobRefs: []
        )
    }

    func latestPromptDebugSnapshot() async throws -> PromptDebugSnapshotDTO? {
        nil
    }

    func providerProfiles() async throws -> [ProviderProfileDTO] {
        providerProfilesForTest
    }

    func activeProvider() async throws -> ProviderProfileDTO {
        activeProviderForTest
    }

    func setProvider(sessionId: String, providerId: String) async throws -> RuntimeEventDTO {
        selectedProviders.append(SelectedProvider(sessionId: sessionId, providerId: providerId))
        if let profile = providerProfilesForTest.first(where: { $0.id == providerId }) {
            activeProviderForTest = profile
        }
        return RuntimeEventDTO(
            id: "provider_changed",
            sessionId: sessionId,
            parentId: nil,
            runId: nil,
            sequence: 0,
            depth: 0,
            kind: .providerChanged,
            payload: #"{"provider_id":"\#(providerId)"}"#,
            blobRefs: []
        )
    }

    func conversationSummaries() async throws -> [ConversationSummaryDTO] {
        conversationSummariesForTest
    }

    func forkSession(sessionId: String, leafId: String) async throws -> String {
        forkSessionRequests.append(ForkSessionRequest(sessionId: sessionId, leafId: leafId))
        return forkSessionResultForTest
    }

    func activeBranch(sessionId: String, leafId: String?) async throws -> [RuntimeEventDTO] {
        activeBranchRequests.append(ActiveBranchRequest(sessionId: sessionId, leafId: leafId))
        return activeBranchEventsForTest[activeBranchKey(sessionId: sessionId, leafId: leafId)] ?? []
    }

    func renameSession(sessionId: String, title: String) async throws {
        renamedSessions.append(RenamedSession(sessionId: sessionId, title: title))
        conversationSummariesForTest = conversationSummariesForTest.map { summary in
            guard summary.sessionId == sessionId else {
                return summary
            }
            var renamed = summary
            renamed.title = title
            return renamed
        }
    }

    func updateRuntimeOptions(_ options: RuntimeOptionsDTO) async throws {
        runtimeOptions.append(RuntimeOptionsSubmission(
            systemPrompt: options.systemPrompt,
            runtimePolicy: options.runtimePolicy,
            temperature: options.temperature,
            topP: options.topP
        ))
    }

    func archiveSession(sessionId: String) async throws {
        archivedSessionIds.append(sessionId)
    }

    func deleteSession(sessionId: String) async throws {
        deletedSessionIds.append(sessionId)
    }

    private func activeBranchKey(sessionId: String, leafId: String?) -> String {
        "\(sessionId)#\(leafId ?? "")"
    }
}

@MainActor
private final class RecordingChatInteractionCoordinator: ChatInteractionCoordinating, @unchecked Sendable {
    private(set) var sentMessages: [String] = []
    private(set) var agentProfileIds: [String] = []
    private(set) var agentProfileRevisionIds: [UInt64] = []
    private(set) var parentEventIds: [String?] = []
    private(set) var options: [ExecutionOptionsDTO] = []
    private let eventsToEmit: [RuntimeEventDTO]
    private let result: ChatInteractionResult

    init(
        eventsToEmit: [RuntimeEventDTO] = [],
        result: ChatInteractionResult = ChatInteractionResult(runId: "run_1", state: .completed)
    ) {
        self.eventsToEmit = eventsToEmit
        self.result = result
    }

    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        agentProfileRevisionId: UInt64,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> ChatInteractionResult {
        sentMessages.append(text)
        agentProfileIds.append(agentProfileId)
        agentProfileRevisionIds.append(agentProfileRevisionId)
        parentEventIds.append(parentEventId)
        self.options.append(options)
        for event in eventsToEmit {
            await onEvent(event)
        }
        return result
    }
}

private let gregorianCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return calendar
}()

private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
    gregorianCalendar.date(from: DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year,
        month: month,
        day: day,
        hour: hour
    ))!
}

private func conversation(
    _ id: String,
    title: String,
    date: Date?,
    searchText: String = ""
) -> ConversationSummaryViewState {
    ConversationSummaryViewState(
        sessionId: id,
        title: title,
        activeLeafId: nil,
        lastEventId: nil,
        lastUpdatedSequence: 1,
        lastMessageDate: date,
        searchText: searchText
    )
}
