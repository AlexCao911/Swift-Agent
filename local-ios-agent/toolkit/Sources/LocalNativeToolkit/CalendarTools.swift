import Foundation
import LocalAgentBridge

public struct NativeCalendarEvent: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startDateISO8601: String
    public var endDateISO8601: String?

    public init(
        id: String,
        title: String,
        startDateISO8601: String,
        endDateISO8601: String?
    ) {
        self.id = id
        self.title = title
        self.startDateISO8601 = startDateISO8601
        self.endDateISO8601 = endDateISO8601
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case startDateISO8601 = "start_date"
        case endDateISO8601 = "end_date"
    }
}

public protocol CalendarEventsFacade: Sendable {
    func searchEvents(query: String) async throws -> [NativeCalendarEvent]
}

public struct CalendarSearchEventsTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "calendar.search_events",
        description: "Search local calendar events.",
        inputSchema: .object(
            properties: [
                "query": .string(),
            ],
            required: ["query"]
        ),
        riskLevel: .readOnly,
        permissionScope: NativePermissionScope("calendar.events"),
        availability: .available
    )

    private let calendar: any CalendarEventsFacade

    public init(calendar: any CalendarEventsFacade) {
        self.calendar = calendar
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let arguments = try Self.decode(CalendarSearchEventsArguments.self, from: argumentsJson)
            let events = try await calendar.searchEvents(query: arguments.query)
            let structuredJson = Self.encode(CalendarSearchEventsPayload(events: events))

            return ToolResultDTO(
                displayText: "\(events.count) calendar events found.",
                modelText: structuredJson,
                structuredJson: structuredJson,
                auditText: "Searched calendar events for query `\(arguments.query)`.",
                sensitivity: .private,
                retention: .session,
                isError: false
            )
        } catch {
            return Self.errorResult("Unable to search calendar events: \(error)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorResult(_ message: String) -> ToolResultDTO {
        ToolResultDTO(
            displayText: message,
            modelText: message,
            structuredJson: #"{"error":"calendar_search_failed"}"#,
            auditText: message,
            sensitivity: .private,
            retention: .session,
            isError: true
        )
    }
}

private struct CalendarSearchEventsArguments: Decodable {
    var query: String
}

private struct CalendarSearchEventsPayload: Encodable {
    var events: [NativeCalendarEvent]
}
