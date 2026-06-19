struct AppContainer {
    let runtimeService: AgentRuntimeService

    @MainActor
    func makeAgentViewModel() -> AgentViewModel {
        AgentViewModel(service: runtimeService)
    }
}
