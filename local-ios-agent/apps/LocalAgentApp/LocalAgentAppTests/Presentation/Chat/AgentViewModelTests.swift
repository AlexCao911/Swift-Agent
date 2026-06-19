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
        #expect(viewModel.state.draft == "   ")
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
        #expect(viewModel.state.draft == "")
        #expect(viewModel.state.messages.map(\.text) == ["hello"])
    }
}

private actor ViewModelServiceStub: AgentRuntimeServicing {
    var sentTexts: [String] = []
    private let preparedState: AgentViewState
    private let sentState: AgentViewState

    init(
        preparedState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_1"),
        sentState: AgentViewState = AgentViewState(phase: .ready, currentSessionId: "session_1")
    ) {
        self.preparedState = preparedState
        self.sentState = sentState
    }

    func prepare() async throws -> AgentViewState {
        preparedState
    }

    func sendMessage(_ text: String, state: AgentViewState) async throws -> AgentViewState {
        sentTexts.append(text)
        return sentState
    }

    func cancel(state: AgentViewState) async throws -> AgentViewState {
        state
    }
}
