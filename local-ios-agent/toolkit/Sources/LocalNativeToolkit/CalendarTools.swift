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
    public let schema: NativeToolSchema

    private let calendar: any CalendarEventsFacade

    public init(calendar: any CalendarEventsFacade) {
        self.schema = Self.makeSchema()
        self.calendar = calendar
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let arguments = try Self.decode(CalendarSearchEventsArguments.self, from: argumentsJson)
            let events = try await calendar.searchEvents(query: arguments.query)

            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "\(events.count) calendar events found.",
                modelText: "Calendar events matching `\(arguments.query)`: \(events.map(\.title).joined(separator: ", "))",
                resultKind: "calendar_events",
                resultPayload: [
                    "count": .number(Double(events.count)),
                    "events": .array(events.map(Self.eventJSONValue)),
                ],
                sourceKind: "calendar",
                sourceId: "calendar.search_events",
                displayName: Self.manifest.title,
                attachmentIds: [],
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "tool_status",
                sourceLabel: "Calendar",
                auditSummary: "Searched calendar events for query `\(arguments.query)`.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return Self.errorResult("Unable to search calendar events: \(error)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func errorResult(_ message: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "calendar.search_events",
            toolCallId: "unknown",
            code: "calendar_search_failed",
            displayText: message,
            auditSummary: message
        )
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.calendar.search_events.v1",
            capabilityId: "calendar.events.search",
            title: "Search Calendar",
            description: "Search local calendar events.",
            mode: .background,
            permissionScope: NativePermissionScope("calendar.events.read_full"),
            requiredPrivacyKeys: ["NSCalendarsFullAccessUsageDescription"],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .openSettings, message: "Calendar access is required."),
            riskLevel: .readOnly,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Calendar Search", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "calendar.search_events",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "query": .string(),
                ],
                required: ["query"]
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }

    private static func eventJSONValue(_ event: NativeCalendarEvent) -> JSONValue {
        .object([
            "id": .string(event.id),
            "title": .string(event.title),
            "start_date": .string(event.startDateISO8601),
            "end_date": .string(event.endDateISO8601 ?? ""),
        ])
    }
}

private struct CalendarSearchEventsArguments: Decodable {
    var query: String
}
