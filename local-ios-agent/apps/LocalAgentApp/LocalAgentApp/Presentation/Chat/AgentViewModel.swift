import Foundation
import Observation

@MainActor
@Observable
final class AgentViewModel {
    var state: AgentViewState

    private let service: any AgentRuntimeServicing

    init(service: any AgentRuntimeServicing, initialState: AgentViewState = AgentViewState()) {
        self.service = service
        self.state = initialState
    }

    func bootstrap() async {
        do {
            state = try await service.prepare()
        } catch {
            state.phase = .failed(message: error.localizedDescription)
            state.errorMessage = error.localizedDescription
        }
    }

    func send() async {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.phase.isRunning else {
            return
        }

        state.draft = ""
        state.errorMessage = nil
        do {
            state = try await service.sendMessage(text, state: state) { [weak self] event in
                await MainActor.run {
                    guard let self else {
                        return
                    }
                    RuntimeEventReducer.apply(event, to: &self.state)
                }
            }
        } catch {
            state.phase = .failed(message: error.localizedDescription)
            state.errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        do {
            state = try await service.cancel(state: state)
        } catch {
            state.phase = .failed(message: error.localizedDescription)
            state.errorMessage = error.localizedDescription
        }
    }
}
