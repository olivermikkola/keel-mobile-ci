import XCTest
#if canImport(KeelHarness)
@testable import KeelHarness
#else
@testable import KeelMobile
#endif

final class CalendarToolsTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testEventsDaysDefaultsAndEnforcesBounds() throws {
        XCTAssertEqual(try CalendarTools.eventsDays([:]), 7)
        XCTAssertEqual(try CalendarTools.eventsDays(["days": "14"]), 14)
        XCTAssertThrowsError(try CalendarTools.eventsDays(["days": "0"]))
        XCTAssertThrowsError(try CalendarTools.eventsDays(["days": "30"]))
        XCTAssertThrowsError(try CalendarTools.eventsDays(["extra": "1"]))
    }

    func testRemindersLimitDefaultsAndEnforcesBounds() throws {
        XCTAssertEqual(try CalendarTools.remindersLimit([:]), 25)
        XCTAssertEqual(try CalendarTools.remindersLimit(["limit": "5"]), 5)
        XCTAssertThrowsError(try CalendarTools.remindersLimit(["limit": "100"]))
    }

    func testCreateReminderValidatesTitleAndDueDate() throws {
        let req = try CalendarTools.createReminderRequest([
            "title": "Buy milk",
            "due": "2026-11-26T09:30",
            "notes": "Oat milk"
        ], timeZone: utc)
        XCTAssertEqual(req.title, "Buy milk")
        XCTAssertNotNil(req.due)
        XCTAssertEqual(req.notes, "Oat milk")

        XCTAssertThrowsError(try CalendarTools.createReminderRequest(["title": "   "], timeZone: utc))
        XCTAssertThrowsError(try CalendarTools.createReminderRequest(["title": "Test", "due": "not-a-date"], timeZone: utc))
    }

    func testCreateEventDefaultsEndToOneHourAndRejectsInvertedRange() throws {
        let req = try CalendarTools.createEventRequest([
            "title": "Design review",
            "start": "2026-11-26T14:00",
            "location": "Studio"
        ], timeZone: utc)
        XCTAssertEqual(req.title, "Design review")
        XCTAssertEqual(req.end.timeIntervalSince(req.start), 3_600, accuracy: 0.1)
        XCTAssertEqual(req.location, "Studio")

        XCTAssertThrowsError(try CalendarTools.createEventRequest([
            "title": "Bad",
            "start": "2026-11-26T14:00",
            "end": "2026-11-26T13:00"
        ], timeZone: utc))
    }

    func testFormattersAreCompactAndBounded() throws {
        let start = try XCTUnwrap(CalendarTools.parseDate("2026-11-26T10:00", timeZone: utc))
        let end = start.addingTimeInterval(3_600)
        let formatted = CalendarTools.formatEvents([
            .init(title: "Standup", start: start, end: end, location: "Room A")
        ], days: 3, timeZone: utc)
        XCTAssertTrue(formatted.contains("2026-11-26 10:00–11:00: Standup @ Room A"))

        let remindersText = CalendarTools.formatReminders([
            .init(title: "Ship beta", due: start)
        ], timeZone: utc)
        XCTAssertTrue(remindersText.contains("- Ship beta (due 2026-11-26 10:00)"))
    }

    func testDirectorCallParsesCalendarTools() throws {
        let call = try XCTUnwrap(DirectorCall.parse("""
        <tool_call>
        <function=create_reminder>
        <parameter=title>Call Mom &amp; Dad</parameter>
        <parameter=due>2026-11-26T18:00</parameter>
        </function>
        </tool_call>
        """))
        XCTAssertEqual(call.name, "create_reminder")
        XCTAssertEqual(call.arguments["title"], "Call Mom & Dad")
        XCTAssertEqual(call.arguments["due"], "2026-11-26T18:00")
    }
}
