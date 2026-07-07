import AppIntents

struct ConversationEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationEntityQuery()

    let id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct ConversationEntityQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [ConversationEntity.ID]) async throws -> [ConversationEntity] {
        identifiers.map { identifier in
            ConversationEntity(id: identifier, title: "Conversation \(identifier)")
        }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        []
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        []
    }
}
