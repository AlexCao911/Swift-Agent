import Foundation

#if canImport(EventKit) && os(iOS)
import EventKit
#endif

public protocol EventKitReminderWriting: Sendable {
    func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder
}

public struct EventKitReminderAdapter: RemindersFacade {
    private let writer: any EventKitReminderWriting

    public init(writer: any EventKitReminderWriting) {
        self.writer = writer
    }

    public func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder {
        try await writer.createReminder(request)
    }
}

#if canImport(EventKit) && os(iOS)
public extension EventKitReminderAdapter {
    init(eventStore: EKEventStore) {
        self.init(writer: EKEventStoreReminderWriter(eventStore: eventStore))
    }
}

public final class EKEventStoreReminderWriter: EventKitReminderWriting, @unchecked Sendable {
    private let eventStore: EKEventStore

    public init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }

    public func createReminder(_ request: NativeReminderCreateRequest) async throws -> NativeReminder {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = request.title
        reminder.notes = request.notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueDate = request.dueDateISO8601.flatMap(Self.date(from:)) {
            reminder.dueDateComponents = Calendar(identifier: .gregorian).dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }
        try eventStore.save(reminder, commit: true)
        return NativeReminder(
            id: reminder.calendarItemIdentifier,
            title: reminder.title,
            notes: reminder.notes,
            dueDateISO8601: request.dueDateISO8601
        )
    }

    private static func date(from value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
#endif
