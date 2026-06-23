import Foundation
import LocalAgentBridge
import Observation

@MainActor
@Observable
final class AgentViewModel {
    var state: AgentViewState

    private let service: any AgentRuntimeServicing
    private let attachmentService: AttachmentService

    init(
        service: any AgentRuntimeServicing,
        attachmentService: AttachmentService = AttachmentService(),
        initialState: AgentViewState = AgentViewState()
    ) {
        self.service = service
        self.attachmentService = attachmentService
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
        guard (!text.isEmpty || !state.draft.attachments.isEmpty), !state.phase.isRunning else {
            return
        }

        let draftForSend = state.draft
        var serviceState = state
        serviceState.draft = draftForSend
        state.draftText = ""
        state.draft.attachments.removeAll()
        state.errorMessage = nil
        do {
            state = try await service.sendMessage(text, state: serviceState) { [weak self] event in
                await MainActor.run {
                    guard let self else {
                        return
                    }
                    RuntimeEventReducer.apply(event, to: &self.state)
                    self.reconcileStreamedUserMessage(
                        event,
                        originalText: text,
                        draft: draftForSend
                    )
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
        await startNewChat(prefilledText: nil)
    }

    func startNewChat(prefilledText: String?) async {
        do {
            state = try await service.newChat(state: state)
            if let text = prefilledText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                state.draftText = text
            }
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
        guard let message = state.messages.first(where: { $0.id == messageId }) else {
            return
        }
        let leafId = message.branchLeafId ?? message.id
        guard let sessionId = message.sessionId ?? state.currentSessionId else {
            state.draft.targetParentEventId = leafId
            return
        }

        do {
            state = try await service.forkConversation(
                sessionId: sessionId,
                leafId: leafId,
                state: state
            )
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func archiveConversation(_ sessionId: String) async {
        do {
            state = try await service.archiveConversation(sessionId: sessionId, state: state)
        } catch {
            state.conversations.errorMessage = error.localizedDescription
        }
    }

    func deleteConversation(_ sessionId: String) async {
        do {
            state = try await service.deleteConversation(sessionId: sessionId, state: state)
        } catch {
            state.conversations.errorMessage = error.localizedDescription
        }
    }

    func clearForkTarget() {
        state.draft.targetParentEventId = nil
    }

    func regenerate(from messageId: String) async {
        do {
            state = try await service.regenerate(from: messageId, state: state)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func editAndResend(messageId: String, text: String) async {
        do {
            state = try await service.editAndResend(messageId: messageId, text: text, state: state)
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func addLink(_ rawValue: String) async {
        do {
            let draft = try await attachmentService.linkDraft(from: rawValue)
            state.draft.attachments.append(draft)
            state.errorMessage = nil
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func addImage(data: Data, suggestedName: String, mimeType: String) async {
        do {
            let draft = try await attachmentService.imageDraft(
                data: data,
                suggestedName: suggestedName,
                mimeType: mimeType
            )
            state.draft.attachments.append(draft)
            state.errorMessage = nil
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func addFile(_ url: URL) async {
        do {
            let draft = try await attachmentService.fileDraft(from: url)
            state.draft.attachments.append(draft)
            state.errorMessage = nil
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func removeAttachment(_ id: String) async {
        guard let attachment = state.draft.attachments.first(where: { $0.id == id }) else {
            return
        }
        state.draft.attachments.removeAll { $0.id == id }
        await attachmentService.removeDraft(attachment)
    }

    private func markRunFailed(_ message: String) {
        state.finishStreamingMessages(as: .failed(message))
        state.lastTerminalReason = .failed(message)
        state.phase = .failed(message: message)
        state.errorMessage = message
    }

    private func reconcileStreamedUserMessage(
        _ event: RuntimeEventDTO,
        originalText: String,
        draft: UserDraftViewState
    ) {
        guard event.kind == .userMessage, !draft.attachments.isEmpty else {
            return
        }
        guard let index = state.messages.firstIndex(where: { $0.id == event.id }) else {
            return
        }

        state.messages[index].text = originalText
        state.messages[index].attachments = draft.attachments.map { AttachmentViewState(draft: $0) }
    }
}
