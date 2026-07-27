import Foundation
import LocalAgentBridge
import LocalAgentLLMHost
import Testing
@testable import LocalAgentApp

@Suite("Agent runtime service")
struct AgentRuntimeServiceTests {
    @Test
    func productionServiceSourceHasNoLegacyLLMRoute() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = try String(
            contentsOf: app.appendingPathComponent(
                "LocalAgentApp/Runtime/AgentRuntimeService.swift"
            ),
            encoding: .utf8
        )
        let appSources = try [
            "LocalAgentApp/State/AgentViewState.swift",
            "LocalAgentApp/Presentation/Chat/AgentViewModel.swift",
            "LocalAgentApp/Presentation/Chat/ChatManagementSheets.swift",
        ].map {
            try String(contentsOf: app.appendingPathComponent($0), encoding: .utf8)
        }.joined()

        #expect(!service.contains("coordinator: (any ChatInteractionCoordinating)?"))
        #expect(!service.contains("LEGACY_COMPATIBILITY_STREAMING_PATH"))
        #expect(!service.contains("ModelRoutingClient"))
        #expect(!service.contains("ProviderControllingRuntimeClient"))
        #expect(!service.contains("RuntimeOptionsControllingRuntimeClient"))
        #expect(!appSources.contains("selectProvider"))
        #expect(!appSources.contains("ModelSettingsViewState"))
    }

    @Test
    func prepareRegistersToolsAndLoadsConversationSummaries() async throws {
        let bridge = MockRuntimeClient(
            conversationSummaries: [
                ConversationSummaryDTO(
                    sessionId: "session_1",
                    title: "First",
                    activeLeafId: nil,
                    lastEventId: nil,
                    lastUpdatedSequence: 1
                ),
            ]
        )
        let coordinator = RecordingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            conversation: bridge,
            execution: bridge,
            coordinator: coordinator,
            toolDriver: MinimalHostToolDriver()
        )

        let state = try await service.prepare()

        #expect(state.phase == .ready)
        #expect(state.currentSessionId == "session_1")
        #expect(state.conversations.conversations.map(\.sessionId) == ["session_1"])
        #expect(await bridge.registeredToolSchemas.map(\.name) == ["debug.echo"])
    }

    @Test
    func missingHostBindingFailsWithoutLegacyOrMockFallback() async throws {
        let bridge = MockRuntimeClient()
        let starter = AppHostRunStarter(selections: AppLLMHostSelectionRegistry())
        let service = AgentRuntimeService(
            conversation: bridge,
            execution: bridge,
            coordinator: makeCoordinator(
                bridge: bridge,
                runStarter: starter
            ),
            toolDriver: MinimalHostToolDriver()
        )
        let state = AgentViewState(
            phase: .ready,
            selectedAgentProfileId: "profile-v2",
            selectedAgentProfileRevisionId: 7
        )

        do {
            _ = try await service.sendMessage("hello", state: state)
            Issue.record("Expected exact host binding failure")
        } catch let failure as LLMHostFailure {
            #expect(failure.code == "execution.host_binding_not_configured")
        }

        #expect(await bridge.startedExecutionRequests.isEmpty)
        #expect(await bridge.sentMessages.isEmpty)
    }

    @Test
    func sendUsesRequiredCoordinatorAndExactProfileRevision() async throws {
        let bridge = MockRuntimeClient()
        let coordinator = RecordingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            conversation: bridge,
            execution: bridge,
            coordinator: coordinator,
            toolDriver: MinimalHostToolDriver()
        )
        let state = AgentViewState(
            phase: .ready,
            currentSessionId: "session_1",
            selectedAgentProfileId: "profile-v2",
            selectedAgentProfileRevisionId: 9
        )

        let result = try await service.sendMessage("hello", state: state)
        let request = await coordinator.requests.first

        #expect(request?.text == "hello")
        #expect(request?.sessionID == "session_1")
        #expect(request?.profileID == "profile-v2")
        #expect(request?.profileRevision == 9)
        #expect(result.phase == .ready)
        #expect(result.lastTerminalReason == .completed)
    }

    @Test
    func missingProfileRevisionFailsBeforeCoordinator() async throws {
        let bridge = MockRuntimeClient()
        let coordinator = RecordingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            conversation: bridge,
            execution: bridge,
            coordinator: coordinator,
            toolDriver: MinimalHostToolDriver()
        )

        await #expect(throws: AgentRuntimeServiceError.missingAgentProfileRevision) {
            try await service.sendMessage(
                "hello",
                state: AgentViewState(
                    phase: .ready,
                    selectedAgentProfileRevisionId: nil
                )
            )
        }
        #expect(await coordinator.requests.isEmpty)
    }

    @Test
    func cancelUsesProviderNeutralExecutionBridge() async throws {
        let bridge = MockRuntimeClient(sessionIds: ["session_1"])
        let coordinator = BlockingChatInteractionCoordinator()
        let service = AgentRuntimeService(
            conversation: bridge,
            execution: bridge,
            coordinator: coordinator,
            toolDriver: MinimalHostToolDriver()
        )
        let state = AgentViewState(
            phase: .ready,
            currentSessionId: "session_1",
            selectedAgentProfileId: "profile-v2",
            selectedAgentProfileRevisionId: 1
        )
        let send = Task {
            try await service.sendMessage("hello", state: state)
        }

        await coordinator.started.wait()
        _ = try await service.cancel(
            state: AgentViewState(phase: .running(runId: "run-host"))
        )
        await coordinator.release.open()
        _ = try await send.value

        #expect(await bridge.cancelledRunIds == ["run-host"])
    }

    @Test
    func newChatDoesNotCreateALegacySession() async throws {
        let bridge = MockRuntimeClient(sessionIds: ["legacy-session"])
        let service = AgentRuntimeService(
            conversation: bridge,
            execution: bridge,
            coordinator: RecordingChatInteractionCoordinator(),
            toolDriver: MinimalHostToolDriver()
        )

        let state = try await service.newChat(
            state: AgentViewState(
                phase: .ready,
                currentSessionId: "legacy-session"
            )
        )

        #expect(state.currentSessionId == nil)
        #expect(try await bridge.sessionIds() == ["legacy-session"])
    }
}

@MainActor
private final class RecordingChatInteractionCoordinator: ChatInteractionCoordinating {
    struct Request: Sendable {
        let text: String
        let sessionID: String?
        let profileID: String
        let profileRevision: UInt64
    }

    private(set) var requests: [Request] = []

    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        agentProfileRevisionId: UInt64,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> ChatInteractionResult {
        requests.append(Request(
            text: text,
            sessionID: sessionId,
            profileID: agentProfileId,
            profileRevision: agentProfileRevisionId
        ))
        return ChatInteractionResult(runId: "run-host", state: .completed)
    }
}

@MainActor
private final class BlockingChatInteractionCoordinator: ChatInteractionCoordinating {
    let started = AsyncGate()
    let release = AsyncGate()

    func sendMessage(
        text: String,
        sessionId: String?,
        parentEventId: String?,
        agentProfileId: String,
        agentProfileRevisionId: UInt64,
        options: ExecutionOptionsDTO,
        onEvent: @MainActor @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> ChatInteractionResult {
        await onEvent(RuntimeEventDTO(
            id: "run-host-started",
            sessionId: sessionId ?? "session_1",
            parentId: parentEventId,
            runId: "run-host",
            sequence: 1,
            depth: 0,
            kind: .unknown(raw: "execution.event"),
            payload: "run.started",
            blobRefs: []
        ))
        await started.open()
        await release.wait()
        return ChatInteractionResult(runId: "run-host", state: .cancelled)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private func makeCoordinator(
    bridge: MockRuntimeClient,
    runStarter: any LLMProductRunStarting
) -> ChatInteractionCoordinator {
    ChatInteractionCoordinator(
        conversation: ConversationDomainAdapter(bridge: bridge),
        execution: ExecutionDomainAdapter(
            profiles: AgentProfileService(bridge: bridge),
            composition: AgentCompositionService(bridge: bridge),
            lifecycle: RunLifecycleService(bridge: bridge),
            events: RunEventStreamService(bridge: bridge),
            tools: ToolApprovalService(bridge: bridge),
            debug: RunDebugService(bridge: bridge),
            inference: InferenceSettingsService(bridge: bridge)
        ),
        toolDriver: MinimalHostToolDriver(),
        runStarter: runStarter
    )
}
