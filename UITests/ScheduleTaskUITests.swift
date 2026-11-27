import XCTest

final class ScheduleTaskUITests: XCTestCase {
    func testScheduleSheetExplainsTapAndShowsTimePicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        let input = app.descendants(matching: .any).matching(identifier: "localChatInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Summarize my notes")
        let addMenu = app.buttons["composerAddMenu"]
        XCTAssertTrue(addMenu.exists)
        // The fixed composer is visible above the keyboard, but XCTest's
        // scroll-to-visible AX action fails for this SwiftUI Menu. Tap its center.
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["scheduleTaskMenuOption"].tap()
        XCTAssertTrue(app.navigationBars["Schedule task"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["confirmScheduleTask"].isEnabled)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Schedule task time and tap explanation"; image.lifetime = .keepAlways; add(image)
        app.buttons["Close"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
    }
}
