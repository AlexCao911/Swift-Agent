import Foundation

#if canImport(EventKit) && os(iOS)
import EventKit
#endif

public struct EventKitCalendarSourceEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date?

    public init(id: String, title: String, startDate: Date, endDate: Date?) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
    }
}

public protocol EventKitCalendarEventSource: Sendable {
    func events(from startDate: Date, to endDate: Date) async throws -> [EventKitCalendarSourceEvent]
}

public struct EventKitCalendarAdapter: CalendarEventsFacade {
    private let source: any EventKitCalendarEventSource
    private let now: @Sendable () -> Date
    private let searchWindowDays: Int

    public init(
        source: any EventKitCalendarEventSource,
        now: @escaping @Sendable () -> Date = Date.init,
        searchWindowDays: Int = 90
    ) {
        self.source = source
        self.now = now
        self.searchWindowDays = searchWindowDays
    }

    public init(
        source: any EventKitCalendarEventSource,
        now: Date,
        searchWindowDays: Int = 90
    ) {
        self.init(source: source, now: { now }, searchWindowDays: searchWindowDays)
    }

    public func searchEvents(query: String) async throws -> [NativeCalendarEvent] {
        let startDate = now()
        let endDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: searchWindowDays,
            to: startDate
        ) ?? startDate
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let events = try await source.events(from: startDate, to: endDate)

        return events
            .filter { event in
                normalizedQuery.isEmpty || event.title.lowercased().contains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.title < rhs.title
                }
                return lhs.startDate < rhs.startDate
            }
            .map { event in
                NativeCalendarEvent(
                    id: event.id,
                    title: event.title,
                    startDateISO8601: Self.iso8601(event.startDate),
                    endDateISO8601: event.endDate.map(Self.iso8601)
                )
            }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

#if canImport(EventKit) && os(iOS)
public extension EventKitCalendarAdapter {
    init(eventStore: EKEventStore, searchWindowDays: Int = 90) {
        self.init(
            source: EKEventStoreCalendarEventSource(eventStore: eventStore),
            searchWindowDays: searchWindowDays
        )
    }
}

public final class EKEventStoreCalendarEventSource: EventKitCalendarEventSource, @unchecked Sendable {
    private let eventStore: EKEventStore

    public init(eventStore: EKEventStore) {
        self.eventStore = eventStore
    }

    public func events(from startDate: Date, to endDate: Date) async throws -> [EventKitCalendarSourceEvent] {
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        return eventStore.events(matching: predicate).map { event in
            EventKitCalendarSourceEvent(
                id: event.calendarItemIdentifier,
                title: event.title ?? "Untitled Event",
                startDate: event.startDate,
                endDate: event.endDate
            )
        }
    }
}
#endif
