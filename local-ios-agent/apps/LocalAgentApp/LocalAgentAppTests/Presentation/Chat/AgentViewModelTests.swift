import Foundation
import LocalAgentBridge
import Testing
@testable import LocalAgentApp

@Suite("Agent view model")
@MainActor
struct AgentViewModelTests {
    @Test("empty draft is not sent")
    func emptyDraftIsNotSent() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: "   ", currentSessionId: "session_1")
        )

        await viewModel.send()

        #expect(await service.sentTexts.isEmpty)
        #expect(viewModel.state.draftText == "   ")
    }

    @Test("successful send trims draft and updates state")
    func successfulSendTrimsDraftAndUpdatesState() async {
        let service = ViewModelServiceStub(
            sentState: AgentViewState(
                phase: .ready,
                messages: [
                    AgentMessageViewState(id: "user_1", role: .user, text: "hello", isStreaming: false),
                ],
                currentSessionId: "session_1"
            )
        )
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: " hello ", currentSessionId: "session_1")
        )

        await viewModel.send()

        #expect(await service.sentTexts == ["hello"])
        #expect(viewModel.state.draftText == "")
        #expect(viewModel.state.messages.map(\.text) == ["hello"])
    }

    @Test("send applies streamed event before final state")
    func sendAppliesStreamedEventBeforeFinalState() async {
        let service = StreamingViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: "hello", currentSessionId: "session_1")
        )

        let sendTask = Task {
            await viewModel.send()
        }
        await service.waitForStreamedEvent()

        #expect(viewModel.state.messages.map(\.text) == ["partial"])

        await service.releaseFinalState()
        await sendTask.value

        #expect(viewModel.state.messages.map(\.text) == ["final"])
    }

    @Test("send failure marks streamed partial output failed")
    func sendFailureMarksStreamedPartialOutputFailed() async {
        let service = FailingStreamingViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, draft: "hello", currentSessionId: "session_1")
        )

        await viewModel.send()

        #expect(viewModel.state.phase == .failed(message: "stream stopped"))
        #expect(viewModel.state.errorMessage == "stream stopped")
        #expect(viewModel.state.lastTerminalReason == .failed("stream stopped"))
        #expect(viewModel.state.messages.map(\.text) == ["partial"])
        #expect(viewModel.state.messages[0].streaming == .failed("stream stopped"))
    }

    @Test("select provider delegates to service")
    func selectProviderDelegatesToService() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.selectProvider("local_llm")

        #expect(await service.selectedProviderIds == ["local_llm"])
    }

    @Test("new chat delegates to service and clears messages")
    func newChatDelegatesToService() async {
        let service = ViewModelServiceStub(
            newChatState: AgentViewState(phase: .ready, messages: [], currentSessionId: "session_2")
        )
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(
                phase: .ready,
                messages: [AgentMessageViewState(id: "user_1", role: .user, text: "old", isStreaming: false)],
                currentSessionId: "session_1"
            )
        )

        await viewModel.newChat()

        #expect(await service.didCreateNewChat)
        #expect(viewModel.state.currentSessionId == "session_2")
        #expect(viewModel.state.messages.isEmpty)
    }

    @Test("fork from message stores target parent event id")
    func forkFromMessageStoresParent() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.forkFromMessage("entry_4")

        #expect(viewModel.state.draft.targetParentEventId == "entry_4")
    }

    @Test("regenerate delegates assistant message id")
    func regenerateDelegatesMessageId() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.regenerate(from: "assistant_1")

        #expect(await service.regeneratedMessageIds == ["assistant_1"])
    }

    @Test("continue generation delegates")
    func continueGenerationDelegates() async {
        let service = ViewModelServiceStub()
        let viewModel = AgentViewModel(
            service: service,
            initialState: AgentViewState(phase: .ready, currentSessionId: "session_1")
        )

        await viewModel.continueGeneration()

        #expect(await service.didContinueGeneration)
    }
}

private actor ViewModelServiceStub: AgentRuntimeServicing {
    var sentTexts: [String] = []
    var selectedProviderIds: [String] = []
    var didCreateNewChat = false
    var regeneratedMessageIds: [String] = []
    var didContinueGeneration = false
    private let preparedState: AgentViewState
    private let sentState: AgentViewState
    private let newChatState: AgentViewState

    init(
        preparedState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_1"),
        sentState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_1"),
        newChatState: AgentViewState = AgentViewState(phase: .ready, messages: [], currentSessionId: "session_2")
    ) {
        self.preparedState = preparedState
        self.sentState = sentState
        self.newChatState = newChatState
    }

    func prepare() async throws -> AgentViewState {
        preparedState
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        sentTexts.append(text)
        return sentState
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState {
        selectedProviderIds.append(providerId)
        return state
    }

    func newChat(state: AgentViewState) async throws -> AgentViewState {
        didCreateNewChat = true
        return newChatState
    }

    func loadConversations(state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func selectConversation(sessionId: String, state: AgentViewState) async throws -> AgentViewState {
        state
    }

    func regenerate(from messageId: String, state: AgentViewState) async throws -> AgentViewState {
        regeneratedMessageIds.append(messageId)
        return state
    }

    func continueGeneration(state: AgentViewState) async throws -> AgentViewState {
        didContinueGeneration = true
        return state
    }
}

private actor StreamingViewModelServiceStub: AgentRuntimeServicing {
    private var streamedEventContinuation: CheckedContinuation<Void, Never>?
    private var finalStateContinuation: CheckedContinuation<Void, Never>?
    private var didStreamEvent = false
    private var canReturnFinalState = false

    func prepare() async throws -> AgentViewState {
        AgentViewState(phase: .ready, currentSessionId: "session_1")
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        await onEvent(RuntimeEventDTO(
            id: "delta_1",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: .assistantTextDelta,
            payload: "partial",
            blobRefs: []
        ))
        didStreamEvent = true
        streamedEventContinuation?.resume()
        streamedEventContinuation = nil

        if !canReturnFinalState {
            await withCheckedContinuation { continuation in
                finalStateContinuation = continuation
            }
        }

        return AgentViewState(
            phase: .ready,
            messages: [
                AgentMessageViewState(
                    id: "assistant_final",
                    role: .assistant,
                    text: "final",
                    isStreaming: false
                ),
            ],
            currentSessionId: "session_1"
        )
    }

    func waitForStreamedEvent() async {
        if didStreamEvent {
            return
        }
        await withCheckedContinuation { continuation in
            streamedEventContinuation = continuation
        }
    }

    func releaseFinalState() {
        canReturnFinalState = true
        finalStateContinuation?.resume()
        finalStateContinuation = nil
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

private actor FailingStreamingViewModelServiceStub: AgentRuntimeServicing {
    func prepare() async throws -> AgentViewState {
        AgentViewState(phase: .ready, currentSessionId: "session_1")
    }

    func sendMessage(
        _ text: String,
        state: AgentViewState,
        onEvent: @Sendable @escaping (RuntimeEventDTO) async -> Void
    ) async throws -> AgentViewState {
        await onEvent(RuntimeEventDTO(
            id: "delta_1",
            sessionId: "session_1",
            parentId: nil,
            runId: "run_1",
            sequence: 1,
            depth: 0,
            kind: .assistantTextDelta,
            payload: "partial",
            blobRefs: []
        ))
        throw StreamingViewModelServiceError.streamStopped
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}

private enum StreamingViewModelServiceError: LocalizedError {
    case streamStopped

    var errorDescription: String? {
        "stream stopped"
    }
}
