import XCTest

final class FileSearchUITests: XCTestCase {
    func testSearchActivityShowsLinesAndExplicitContinuation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--search-activity-fixture"]
        app.launch()
        let activity = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Search Sources/Parser.swift")).firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "4  func parse(_ input: String) {")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "More matches from line 10.")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Verified file search activity - visual fixture"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
