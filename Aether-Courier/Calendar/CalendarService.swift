import Foundation
import EventKit

/// Read/write access to the user's calendars via EventKit. On macOS, EventKit
/// already federates iCloud, Google, Exchange/Outlook, and local calendars that
/// the user has added in System Settings, so this single integration covers the
/// "Mac / Outlook / Gmail / iCloud calendars" requirement without per-provider
/// CalDAV code. (Proton Calendar has no public API and is out of scope.)
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private(set) var authorized = false

    /// Requests calendar access (full access on macOS 14+).
    func requestAccess() async {
        do {
            authorized = try await store.requestFullAccessToEvents()
        } catch {
            authorized = false
        }
    }

    /// Events between two dates across all calendars.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        guard authorized else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { CalendarEvent(
                id: $0.eventIdentifier ?? UUID().uuidString,
                title: $0.title ?? "(No title)",
                start: $0.startDate,
                end: $0.endDate,
                calendarName: $0.calendar.title,
                isAllDay: $0.isAllDay
            )}
    }

    /// A concise availability summary for the copilot "Show my availability".
    func availabilitySummary(days: Int = 3) -> String {
        guard authorized else { return "Calendar access not granted." }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now)!
        let upcoming = events(from: now, to: end)
        guard !upcoming.isEmpty else { return "No events in the next \(days) days — you're wide open." }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE h:mm a"
        return upcoming.prefix(12)
            .map { "• \(fmt.string(from: $0.start)) — \($0.title) [\($0.calendarName)]" }
            .joined(separator: "\n")
    }

    /// Creates an event in the default calendar (used by copilot scheduling).
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, notes: String? = nil) -> Bool {
        guard authorized else { return false }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}

struct CalendarEvent: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarName: String
    let isAllDay: Bool
}
