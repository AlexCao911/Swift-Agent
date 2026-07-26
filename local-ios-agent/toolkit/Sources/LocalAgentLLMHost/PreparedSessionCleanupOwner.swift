import LocalAgentLLMContracts

package actor PreparedSessionCleanupOwner {
    package typealias Compensator = @Sendable () async -> Void

    private enum State {
        case open([(id: String, compensator: Compensator)])
        case closing(Task<Void, Never>)
        case closed
    }

    private var state: State = .open([])

    package init() {}

    package func register(
        id: String,
        _ compensator: @escaping Compensator
    ) async {
        switch state {
        case var .open(compensators):
            guard !compensators.contains(where: { $0.id == id }) else {
                return
            }
            compensators.append((id, compensator))
            state = .open(compensators)

        case let .closing(closeTask):
            await closeTask.value
            await compensator()

        case .closed:
            await compensator()
        }
    }

    package func close() async -> LLMBackendSessionCloseDisposition {
        switch state {
        case let .open(compensators):
            let closeTask = Task {
                for item in compensators.reversed() {
                    await item.compensator()
                }
            }
            state = .closing(closeTask)
            await closeTask.value
            state = .closed
            return .closed

        case let .closing(closeTask):
            await closeTask.value
            return .alreadyClosed

        case .closed:
            return .alreadyClosed
        }
    }
}
