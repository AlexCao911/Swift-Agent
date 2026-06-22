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
            markRunFailed(error.localizedDescription)
        }
    }

    func send() async {
        let text = state.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.phase.isRunning else {
            return
        }

        state.draftText = ""
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
            markRunFailed(error.localizedDescription)
        }
    }

    func cancel() async {
        do {
            state = try await service.cancel(state: state)
        } catch {
            markRunFailed(error.localizedDescription)
        }
    }

    func selectProvider(_ providerId: String) async {
        do {
            state = try await service.selectProvider(providerId, state: state)
        } catch {
            state.provider.errorMessage = error.localizedDescription
        }
    }

    func newChat() async {
        do {
            state = try await service.newChat(state: state)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func loadConversations() async {
        do {
            state = try await service.loadConversations(state: state)
        } catch {
            state.conversations.errorMessage = error.localizedDescription
        }
    }

    func selectConversation(_ sessionId: String) async {
        do {
            state = try await service.selectConversation(sessionId: sessionId, state: state)
        } catch {
            state.conversations.errorMessage = error.localizedDescription
        }
    }

    func forkFromMessage(_ messageId: String) async {
        state.draft.targetParentEventId = messageId
    }

    private func markRunFailed(_ message: String) {
        state.finishStreamingMessages(as: .failed(message))
        state.lastTerminalReason = .failed(message)
        state.phase = .failed(message: message)
        state.errorMessage = message
    }
}
