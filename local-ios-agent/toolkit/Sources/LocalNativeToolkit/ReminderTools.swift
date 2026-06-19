import Foundation
import LocalAgentBridge

public struct NativeReminderCreateRequest: Codable, Equatable, Sendable {
    public var title: String
    public var notes: String?
    public var dueDateISO8601: String?

    public init(title: String, notes: String?, dueDateISO8601: String?) {
        self.title = title
        self.notes = notes
        self.dueDateISO8601 = dueDateISO8601
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case notes
        case dueDateISO8601 = "due_date"
    }
}

public struct NativeReminder: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var notes: String?
    public var dueDateISO8601: String?

    public init(id: String, title: String, notes: String?, dueDateISO8601: String?) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDateISO8601 = dueDateISO8601
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case notes
        case dueDateISO8601 = "due_date"
    }
}

public protocol RemindersFacade: Sendable {
    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder
}

public struct RemindersCreateReminderTool: NativeTool {
    public let schema = NativeToolSchema(
        name: "reminders.create_reminder",
        description: "Create a local reminder.",
        inputSchema: .object(
            properties: [
                "title": .string(),
                "notes": .string(),
                "due_date": .string(),
            ],
            required: ["title"]
        ),
        riskLevel: .confirm,
        permissionScope: NativePermissionScope("reminders"),
        availability: .available
    )

    private let reminders: any RemindersFacade

    public init(reminders: any RemindersFacade) {
        self.reminders = reminders
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let request = try Self.decode(NativeReminderCreateRequest.self, from: argumentsJson)
            let reminder = try await reminders.createReminder(request)
            let structuredJson = Self.encode(NativeReminderPayload(reminder: reminder))

            return ToolResultDTO(
                displayText: "Reminder created: \(reminder.title)",
                modelText: structuredJson,
                structuredJson: structuredJson,
                auditText: "Created reminder `\(reminder.id)`.",
                sensitivity: .private,
                retention: .session,
                isError: false
            )
        } catch {
            return Self.errorResult("Unable to create reminder: \(error)")
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
            structuredJson: #"{"error":"reminder_create_failed"}"#,
            auditText: message,
            sensitivity: .private,
            retention: .session,
            isError: true
        )
    }
}

private struct NativeReminderPayload: Encodable {
    var reminder: NativeReminder
}
