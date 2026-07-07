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
    public let schema: NativeToolSchema

    private let reminders: any RemindersFacade

    public init(reminders: any RemindersFacade) {
        self.schema = Self.makeSchema()
        self.reminders = reminders
    }

    public func execute(argumentsJson: String) async -> ToolResultDTO {
        do {
            let request = try Self.decode(NativeReminderCreateRequest.self, from: argumentsJson)
            let reminder = try await reminders.createReminder(request)

            return NativeToolResultBuilder.success(
                manifestId: Self.manifest.manifestId,
                toolName: schema.name,
                toolCallId: "unknown",
                displayText: "Reminder created: \(reminder.title)",
                modelText: "Reminder created: \(reminder.title)",
                resultKind: "reminder_created",
                resultPayload: [
                    "reminder": .object([
                        "id": .string(reminder.id),
                        "title": .string(reminder.title),
                        "notes": .string(reminder.notes ?? ""),
                        "due_date": .string(reminder.dueDateISO8601 ?? ""),
                    ]),
                ],
                sourceKind: "reminders",
                sourceId: reminder.id,
                displayName: Self.manifest.title,
                attachmentIds: [],
                trustLevel: Self.manifest.trustLevel,
                sensitivity: .private,
                retention: Self.manifest.retention,
                modelTextPolicy: "tool_status",
                sourceLabel: "Reminders",
                auditSummary: "Created reminder `\(reminder.id)`.",
                auditRedaction: Self.manifest.audit.resultSummaryPolicy.rawValue
            )
        } catch {
            return Self.errorResult("Unable to create reminder: \(error)")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func errorResult(_ message: String) -> ToolResultDTO {
        NativeToolResultBuilder.error(
            manifestId: manifest.manifestId,
            toolName: "reminders.create_reminder",
            toolCallId: "unknown",
            code: "reminder_create_failed",
            displayText: message,
            auditSummary: message,
            sensitivity: .private,
            retention: manifest.retention
        )
    }

    private static var manifest: NativeToolManifest {
        NativeToolManifest(
            manifestId: "native.reminders.create_reminder.v1",
            capabilityId: "reminders.create_reminder",
            title: "Create Reminder",
            description: "Create a local reminder.",
            mode: .background,
            permissionScope: NativePermissionScope("reminders"),
            requiredPrivacyKeys: ["NSRemindersUsageDescription"],
            requiresForegroundUI: false,
            minimumOS: "iOS 17.0",
            regionPolicy: "available_with_service_fallback",
            fallback: NativeToolFallback(kind: .openSettings, message: "Reminders access is required."),
            riskLevel: .confirm,
            approvalPolicy: .perCall,
            trustLevel: .trustedToolResult,
            retention: .runOnly,
            audit: NativeToolAudit(label: "Create Reminder", resultSummaryPolicy: .metadataOnly)
        )
    }

    private static func makeSchema() -> NativeToolSchema {
        NativeToolSchema(
            name: "reminders.create_reminder",
            description: manifest.description,
            inputSchema: .object(
                properties: [
                    "title": .string(),
                    "notes": .string(),
                    "due_date": .string(),
                ],
                required: ["title"]
            ),
            riskLevel: manifest.riskLevel,
            permissionScope: manifest.permissionScope,
            availability: .available,
            manifest: manifest
        )
    }
}
