import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(KeelHarness)
import KeelHarness
#endif

/// On-device EventKit bridge for `calendar_events`, `reminders_list`,
/// `create_reminder`, and `create_calendar_event`.
/// Write operations are ONLY called after explicit user approval in `LocalChat`.
enum CalendarBridge {
    enum BridgeError: LocalizedError {
        case denied(String)
        case noDefaultList(String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .denied(let kind):
                return "\(kind) access is not allowed. Enable it for Keel Mobile in iOS Settings → Privacy & Security."
            case .noDefaultList(let kind):
                return "No default \(kind) list is configured on this device."
            case .unsupported:
                return "Calendar and Reminders are unavailable on this platform."
            }
        }
    }

    static func listEvents(days: Int) async throws -> [CalendarTools.EventSummary] {
        #if canImport(EventKit)
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw BridgeError.denied("Calendar") }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(CalendarTools.maxItems)
        return events.map { event in
            CalendarTools.EventSummary(
                title: event.title ?? "(Untitled event)",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? event.location : nil
            )
        }
        #else
        throw BridgeError.unsupported
        #endif
    }

    static func listReminders(limit: Int) async throws -> [CalendarTools.ReminderSummary] {
        #if canImport(EventKit)
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw BridgeError.denied("Reminders") }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items ?? [])
            }
        }
        let sorted = reminders.sorted { lhs, rhs in
            let lDate = lhs.dueDateComponents?.date ?? .distantFuture
            let rDate = rhs.dueDateComponents?.date ?? .distantFuture
            return lDate < rDate
        }
        return sorted.prefix(limit).map { item in
            CalendarTools.ReminderSummary(
                title: item.title ?? "(Untitled reminder)",
                due: item.dueDateComponents?.date,
                notes: item.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? item.notes : nil
            )
        }
        #else
        throw BridgeError.unsupported
        #endif
    }

    static func createReminder(_ request: CalendarTools.CreateReminderRequest) async throws -> String {
        #if canImport(EventKit)
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw BridgeError.denied("Reminders") }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw BridgeError.noDefaultList("Reminders")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = request.title
        reminder.notes = request.notes
        if let due = request.due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        try store.save(reminder, commit: true)
        return "Created reminder \"\(request.title)\" in \(list.title)."
        #else
        throw BridgeError.unsupported
        #endif
    }

    static func createEvent(_ request: CalendarTools.CreateEventRequest) async throws -> String {
        #if canImport(EventKit)
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToEvents()
        guard granted else { throw BridgeError.denied("Calendar") }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw BridgeError.noDefaultList("Calendar")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = request.title
        event.startDate = request.start
        event.endDate = request.end
        event.location = request.location
        event.notes = request.notes
        try store.save(event, span: .thisEvent, commit: true)
        return "Added event \"\(request.title)\" to \(calendar.title)."
        #else
        throw BridgeError.unsupported
        #endif
    }
}
