import Foundation

/// On-device Calendar & Reminders tools (`EventKit`).
/// - Read tools (`calendar_events`, `reminders_list`) are bounded in date range, count, and output length.
/// - Write tools (`create_reminder`, `create_calendar_event`) validate inputs strictly and ALWAYS
///   require explicit user approval in the UI before EventKit writes anything.
public enum CalendarTools {
    public static let maxDaysAhead = 14
    public static let defaultDaysAhead = 7
    public static let maxItems = 25
    public static let maxTitleCharacters = 120
    public static let maxNotesCharacters = 1_000
    public static let maxLocationCharacters = 160
    public static let maxOutputCharacters = 4_000

    public enum Problem: LocalizedError, Equatable {
        case badArguments(String)
        case titleEmpty
        case titleTooLong
        case notesTooLong
        case locationTooLong
        case invalidDays
        case invalidLimit
        case invalidDate(String)
        case endBeforeStart

        public var errorDescription: String? {
            switch self {
            case .badArguments(let detail): return detail
            case .titleEmpty: return "Expected a non-empty title."
            case .titleTooLong: return "Title is at most \(CalendarTools.maxTitleCharacters) characters."
            case .notesTooLong: return "Notes are at most \(CalendarTools.maxNotesCharacters) characters."
            case .locationTooLong: return "Location is at most \(CalendarTools.maxLocationCharacters) characters."
            case .invalidDays: return "Expected days between 1 and \(CalendarTools.maxDaysAhead)."
            case .invalidLimit: return "Expected limit between 1 and \(CalendarTools.maxItems)."
            case .invalidDate(let field): return "Expected \(field) as ISO-8601 date/time (e.g. 2026-11-25T14:30 or 2026-11-25)."
            case .endBeforeStart: return "Event end time must be after start time."
            }
        }
    }

    public struct EventSummary: Equatable, Sendable {
        public let title: String
        public let start: Date
        public let end: Date
        public let isAllDay: Bool
        public let location: String?

        public init(title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil) {
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.location = location
        }
    }

    public struct ReminderSummary: Equatable, Sendable {
        public let title: String
        public let due: Date?
        public let notes: String?

        public init(title: String, due: Date? = nil, notes: String? = nil) {
            self.title = title
            self.due = due
            self.notes = notes
        }
    }

    public struct CreateReminderRequest: Equatable, Sendable {
        public let title: String
        public let due: Date?
        public let notes: String?
    }

    public struct CreateEventRequest: Equatable, Sendable {
        public let title: String
        public let start: Date
        public let end: Date
        public let location: String?
        public let notes: String?
    }

    public static let eventsTool = #"{"type":"function","function":{"name":"calendar_events","description":"List upcoming events from the user's Calendar for the next 1 to 14 days (default 7). Read-only.","parameters":{"type":"object","properties":{"days":{"type":"integer"}},"required":[]}}}"#

    public static let remindersTool = #"{"type":"function","function":{"name":"reminders_list","description":"List incomplete items from the user's Reminders (up to 25). Read-only.","parameters":{"type":"object","properties":{"limit":{"type":"integer"}},"required":[]}}}"#

    public static let createReminderTool = #"{"type":"function","function":{"name":"create_reminder","description":"Propose adding a new item to the user's Reminders. The user must approve before it is created. Optional due uses YYYY-MM-DD or YYYY-MM-DDTHH:MM.","parameters":{"type":"object","properties":{"title":{"type":"string"},"due":{"type":"string"},"notes":{"type":"string"}},"required":["title"]}}}"#

    public static let createEventTool = #"{"type":"function","function":{"name":"create_calendar_event","description":"Propose adding a new event to the user's Calendar. The user must approve before it is added. start (and optional end, default +1 hour) use YYYY-MM-DDTHH:MM.","parameters":{"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},"location":{"type":"string"},"notes":{"type":"string"}},"required":["title","start"]}}}"#

    public static let allTools = [eventsTool, remindersTool, createReminderTool, createEventTool]
    public static let toolNames: Set<String> = ["calendar_events", "reminders_list", "create_reminder", "create_calendar_event"]

    public static func eventsDays(_ arguments: [String: String]) throws -> Int {
        guard Set(arguments.keys).isSubset(of: ["days"]) else {
            throw Problem.badArguments("calendar_events accepts only an optional days integer (1–\(maxDaysAhead)).")
        }
        guard let raw = arguments["days"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return defaultDaysAhead
        }
        guard let days = Int(raw), (1...maxDaysAhead).contains(days) else { throw Problem.invalidDays }
        return days
    }

    public static func remindersLimit(_ arguments: [String: String]) throws -> Int {
        guard Set(arguments.keys).isSubset(of: ["limit"]) else {
            throw Problem.badArguments("reminders_list accepts only an optional limit integer (1–\(maxItems)).")
        }
        guard let raw = arguments["limit"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return maxItems
        }
        guard let limit = Int(raw), (1...maxItems).contains(limit) else { throw Problem.invalidLimit }
        return limit
    }

    public static func createReminderRequest(_ arguments: [String: String], timeZone: TimeZone = .current) throws -> CreateReminderRequest {
        guard Set(arguments.keys).isSubset(of: ["title", "due", "notes"]) else {
            throw Problem.badArguments("create_reminder accepts title and optional due, notes.")
        }
        let title = cleanOneLine(arguments["title"] ?? "")
        guard !title.isEmpty else { throw Problem.titleEmpty }
        guard title.count <= maxTitleCharacters else { throw Problem.titleTooLong }

        let due: Date?
        if let rawDue = arguments["due"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDue.isEmpty {
            guard let parsed = parseDate(rawDue, timeZone: timeZone) else { throw Problem.invalidDate("due") }
            due = parsed
        } else {
            due = nil
        }

        let notes = arguments["notes"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let notes, notes.count > maxNotesCharacters { throw Problem.notesTooLong }
        return CreateReminderRequest(title: title, due: due, notes: notes?.isEmpty == false ? notes : nil)
    }

    public static func createEventRequest(_ arguments: [String: String], timeZone: TimeZone = .current) throws -> CreateEventRequest {
        guard Set(arguments.keys).isSubset(of: ["title", "start", "end", "location", "notes"]) else {
            throw Problem.badArguments("create_calendar_event accepts title, start, and optional end, location, notes.")
        }
        let title = cleanOneLine(arguments["title"] ?? "")
        guard !title.isEmpty else { throw Problem.titleEmpty }
        guard title.count <= maxTitleCharacters else { throw Problem.titleTooLong }

        let rawStart = (arguments["start"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = parseDate(rawStart, timeZone: timeZone) else { throw Problem.invalidDate("start") }

        let end: Date
        if let rawEnd = arguments["end"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawEnd.isEmpty {
            guard let parsedEnd = parseDate(rawEnd, timeZone: timeZone) else { throw Problem.invalidDate("end") }
            guard parsedEnd > start else { throw Problem.endBeforeStart }
            end = parsedEnd
        } else {
            end = start.addingTimeInterval(3_600)
        }

        let location = arguments["location"].map(cleanOneLine)
        if let location, location.count > maxLocationCharacters { throw Problem.locationTooLong }
        let notes = arguments["notes"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let notes, notes.count > maxNotesCharacters { throw Problem.notesTooLong }

        return CreateEventRequest(
            title: title,
            start: start,
            end: end,
            location: location?.isEmpty == false ? location : nil,
            notes: notes?.isEmpty == false ? notes : nil
        )
    }

    /// Parses common ISO-8601 date/time strings emitted by small models (`YYYY-MM-DD`,
    /// `YYYY-MM-DDTHH:MM`, `YYYY-MM-DD HH:MM`, or full RFC3339 with timezone).
    public static func parseDate(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoWithZone = ISO8601DateFormatter()
        isoWithZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithZone.date(from: trimmed) { return date }
        isoWithZone.formatOptions = [.withInternetDateTime]
        if let date = isoWithZone.date(from: trimmed) { return date }

        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    public static func formatEvents(_ events: [EventSummary], days: Int, timeZone: TimeZone = .current) -> String {
        guard !events.isEmpty else {
            return "No calendar events in the next \(days) day\(days == 1 ? "" : "s")."
        }
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = timeZone
        dayFmt.dateFormat = "yyyy-MM-dd"

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = timeZone
        timeFmt.dateFormat = "HH:mm"

        var lines: [String] = ["Upcoming events (next \(days) day\(days == 1 ? "" : "s")):"]
        for event in events.prefix(maxItems) {
            let when = event.isAllDay
                ? "\(dayFmt.string(from: event.start)) (all day)"
                : "\(dayFmt.string(from: event.start)) \(timeFmt.string(from: event.start))–\(timeFmt.string(from: event.end))"
            let whereText = event.location.map { " @ \($0)" } ?? ""
            lines.append("- \(when): \(event.title)\(whereText)")
        }
        if events.count > maxItems {
            lines.append("(Showing \(maxItems) of \(events.count) events.)")
        }
        return boundOutput(lines.joined(separator: "\n"))
    }

    public static func formatReminders(_ reminders: [ReminderSummary], timeZone: TimeZone = .current) -> String {
        guard !reminders.isEmpty else {
            return "No incomplete reminders."
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = ["Incomplete reminders:"]
        for item in reminders.prefix(maxItems) {
            let due = item.due.map { " (due \(fmt.string(from: $0)))" } ?? ""
            lines.append("- \(item.title)\(due)")
        }
        if reminders.count > maxItems {
            lines.append("(Showing \(maxItems) of \(reminders.count) reminders.)")
        }
        return boundOutput(lines.joined(separator: "\n"))
    }

    private static func cleanOneLine(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundOutput(_ text: String) -> String {
        guard text.count > maxOutputCharacters else { return text }
        return String(text.prefix(maxOutputCharacters - 20)) + "\n… (output truncated)"
    }
}
