import Combine

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var sessions: [ChatSession]
    @Published private(set) var messagesByConversation: [String: [ChatMessage]]

    init(
        sessions: [ChatSession] = [],
        messagesByConversation: [String: [ChatMessage]] = [:]
    ) {
        self.sessions = sessions
        self.messagesByConversation = messagesByConversation
    }

    func projectedMessages(conversationStreamID: String) -> [ChatMessage] {
        messagesByConversation[conversationStreamID, default: []]
    }
}
