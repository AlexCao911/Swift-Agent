import Foundation
import Testing
import LocalAgentBridge
@testable import LocalNativeToolkit

@Suite("Native capability tools")
struct NativeCapabilityToolsTests {
    @Test
    func calendarSearchEventsUsesInjectedFacade() async throws {
        let facade = RecordingCalendarFacade(events: [
            NativeCalendarEvent(
                id: "event_1",
                title: "Team standup",
                startDateISO8601: "2026-06-18T10:00:00Z",
                endDateISO8601: nil
            ),
        ])
        let tool = CalendarSearchEventsTool(calendar: facade)

        #expect(tool.schema.name == "calendar.search_events")
        #expect(tool.schema.riskLevel == .readOnly)
        #expect(tool.schema.permissionScope == NativePermissionScope("calendar.events.read_full"))
        #expect(tool.schema.inputSchema.jsonString == #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)

        let result = await tool.execute(argumentsJson: #"{"query":"standup"}"#)
        let object = try decodedJSONObject(result.structuredJson)
        let payload = try #require(object["result"] as? [String: Any])
        let events = try #require(payload["events"] as? [[String: Any]])

        #expect(await facade.queries == ["standup"])
        #expect(result.isError == false)
        #expect(result.sensitivity == .private)
        #expect(events.map { $0["title"] as? String } == ["Team standup"])
    }

    @Test
    func remindersCreateReminderUsesInjectedFacade() async throws {
        let facade = RecordingRemindersFacade(reminder: NativeReminder(
            id: "reminder_1",
            title: "Buy milk",
            notes: "2%",
            dueDateISO8601: "2026-06-20T09:00:00Z"
        ))
        let tool = RemindersCreateReminderTool(reminders: facade)

        #expect(tool.schema.name == "reminders.create_reminder")
        #expect(tool.schema.riskLevel == .confirm)
        #expect(tool.schema.permissionScope == NativePermissionScope("reminders"))
        #expect(tool.schema.inputSchema.jsonString == #"{"type":"object","properties":{"due_date":{"type":"string"},"notes":{"type":"string"},"title":{"type":"string"}},"required":["title"]}"#)

        let result = await tool.execute(
            argumentsJson: #"{"title":"Buy milk","notes":"2%","due_date":"2026-06-20T09:00:00Z"}"#
        )
        let object = try decodedJSONObject(result.structuredJson)
        let payload = try #require(object["result"] as? [String: Any])
        let reminder = try #require(payload["reminder"] as? [String: Any])

        #expect(await facade.createdRequests == [
            NativeReminderCreateRequest(
                title: "Buy milk",
                notes: "2%",
                dueDateISO8601: "2026-06-20T09:00:00Z"
            ),
        ])
        #expect(result.isError == false)
        #expect(result.sensitivity == .private)
        #expect(reminder["id"] as? String == "reminder_1")
    }

    @Test
    func shortcutsListVoiceShortcutsUsesInjectedFacade() async throws {
        let facade = RecordingShortcutsFacade(shortcuts: [
            NativeVoiceShortcut(name: "Start focus", phrase: "focus time"),
        ])
        let tool = ShortcutsListVoiceShortcutsTool(shortcuts: facade)

        #expect(tool.schema.name == "shortcuts.list_voice_shortcuts")
        #expect(tool.schema.riskLevel == .readOnly)
        #expect(tool.schema.permissionScope == NativePermissionScope("shortcuts"))

        let result = await tool.execute(argumentsJson: "{}")
        let object = try decodedJSONObject(result.structuredJson)
        let shortcuts = try #require(object["shortcuts"] as? [[String: Any]])

        #expect(await facade.listCallCount == 1)
        #expect(result.isError == false)
        #expect(result.sensitivity == .private)
        #expect(shortcuts.map { $0["phrase"] as? String } == ["focus time"])
    }

    private func decodedJSONObject(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor RecordingCalendarFacade: CalendarEventsFacade {
    private let events: [NativeCalendarEvent]
    private var recordedQueries: [String] = []

    init(events: [NativeCalendarEvent]) {
        self.events = events
    }

    var queries: [String] {
        recordedQueries
    }

    func searchEvents(query: String) async throws -> [NativeCalendarEvent] {
        recordedQueries.append(query)
        return events
    }
}

private actor RecordingRemindersFacade: RemindersFacade {
    private let reminder: NativeReminder
    private var requests: [NativeReminderCreateRequest] = []

    init(reminder: NativeReminder) {
        self.reminder = reminder
    }

    var createdRequests: [NativeReminderCreateRequest] {
        requests
    }

    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder {
        requests.append(request)
        return reminder
    }
}

private actor RecordingShortcutsFacade: ShortcutsFacade {
    private let shortcuts: [NativeVoiceShortcut]
    private var calls = 0

    init(shortcuts: [NativeVoiceShortcut]) {
        self.shortcuts = shortcuts
    }

    var listCallCount: Int {
        calls
    }

    func listVoiceShortcuts() async throws -> [NativeVoiceShortcut] {
        calls += 1
        return shortcuts
    }
}
