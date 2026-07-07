import Foundation
import Testing
@testable import LocalNativeToolkit

@Suite("EventKit adapter contracts")
struct EventKitAdapterContractTests {
    @Test
    func calendarAdapterFiltersByQueryAndSortsUpcomingEvents() async throws {
        let source = FakeCalendarEventSource(events: [
            EventKitCalendarSourceEvent(
                id: "event_late",
                title: "Team planning",
                startDate: date("2026-07-08T12:00:00Z"),
                endDate: date("2026-07-08T13:00:00Z")
            ),
            EventKitCalendarSourceEvent(
                id: "event_early",
                title: "Team standup",
                startDate: date("2026-07-08T09:00:00Z"),
                endDate: nil
            ),
            EventKitCalendarSourceEvent(
                id: "event_other",
                title: "Dentist",
                startDate: date("2026-07-08T08:00:00Z"),
                endDate: nil
            ),
        ])
        let adapter = EventKitCalendarAdapter(
            source: source,
            now: date("2026-07-07T00:00:00Z"),
            searchWindowDays: 7
        )

        let events = try await adapter.searchEvents(query: "team")

        #expect(events.map(\.id) == ["event_early", "event_late"])
        #expect(events[0].startDateISO8601 == "2026-07-08T09:00:00Z")
        #expect(await source.requestedWindows.count == 1)
    }

    @Test
    func reminderAdapterWritesTitleNotesAndDueDate() async throws {
        let writer = FakeReminderWriter(reminder: NativeReminder(
            id: "reminder_1",
            title: "Pay rent",
            notes: "Before noon",
            dueDateISO8601: "2026-07-10T09:00:00Z"
        ))
        let adapter = EventKitReminderAdapter(writer: writer)
        let request = NativeReminderCreateRequest(
            title: "Pay rent",
            notes: "Before noon",
            dueDateISO8601: "2026-07-10T09:00:00Z"
        )

        let reminder = try await adapter.createReminder(request)

        #expect(reminder.id == "reminder_1")
        #expect(await writer.requests == [request])
    }

    @Test
    func missingCalendarPermissionBecomesPrivateToolError() async throws {
        let tool = CalendarSearchEventsTool(calendar: FailingCalendarFacade())

        let result = await tool.execute(argumentsJson: #"{"query":"team"}"#)

        #expect(result.isError == true)
        #expect(result.sensitivity == .private)
        #expect(result.structuredJson.contains("calendar_search_failed") == true)
    }

    private func date(_ iso8601: String) -> Date {
        ISO8601DateFormatter().date(from: iso8601)!
    }
}

private actor FakeCalendarEventSource: EventKitCalendarEventSource {
    private let events: [EventKitCalendarSourceEvent]
    private var windows: [(Date, Date)] = []

    init(events: [EventKitCalendarSourceEvent]) {
        self.events = events
    }

    var requestedWindows: [(Date, Date)] {
        windows
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [EventKitCalendarSourceEvent] {
        windows.append((startDate, endDate))
        return events
    }
}

private actor FakeReminderWriter: EventKitReminderWriting {
    private let reminder: NativeReminder
    private var recordedRequests: [NativeReminderCreateRequest] = []

    init(reminder: NativeReminder) {
        self.reminder = reminder
    }

    var requests: [NativeReminderCreateRequest] {
        recordedRequests
    }

    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder {
        recordedRequests.append(request)
        return reminder
    }
}

private struct FailingCalendarFacade: CalendarEventsFacade {
    func searchEvents(query: String) async throws -> [NativeCalendarEvent] {
        throw NativePermissionTestError.denied
    }
}

private enum NativePermissionTestError: Error {
    case denied
}
