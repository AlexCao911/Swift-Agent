import AppIntents

struct AgentEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentEntityQuery()

    let id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

struct AgentEntityQuery: EntityStringQuery, Sendable {
    func entities(for identifiers: [AgentEntity.ID]) async throws -> [AgentEntity] {
        identifiers.map { identifier in
            AgentEntity(id: identifier, displayName: "Agent \(identifier)")
        }
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        []
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        []
    }
}
