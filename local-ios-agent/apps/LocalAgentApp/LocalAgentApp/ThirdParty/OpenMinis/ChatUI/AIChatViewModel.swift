import Foundation
import SwiftUI

typealias InputAttachment = AttachmentDraftViewState
typealias ChatMessage = AgentMessageViewState
typealias ChatSession = ConversationSummaryViewState

@MainActor
final class AIChatViewModel: ObservableObject {
    struct Submission: Equatable, Sendable {
        var conversationStreamID: String
        var text: String
        var attachments: [InputAttachment]
    }

    typealias Submit = @MainActor @Sendable (Submission) async throws -> Void

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var inputAttachments: [InputAttachment] = []
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    let conversationStreamID: String
    private let submit: Submit

    init(
        conversationStreamID: String,
        submit: @escaping Submit
    ) {
        self.conversationStreamID = conversationStreamID
        self.submit = submit
    }

    func send() async {
        guard !isRunning else {
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !inputAttachments.isEmpty else {
            return
        }

        let submission = Submission(
            conversationStreamID: conversationStreamID,
            text: text,
            attachments: inputAttachments
        )

        isRunning = true
        errorMessage = nil
        defer { isRunning = false }

        do {
            try await submit(submission)
            draft = ""
            inputAttachments = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
