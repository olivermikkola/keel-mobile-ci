import XCTest

final class WebSearchUITests: XCTestCase {
    func testConnectionsExplainsSearchAndKeepsTheKeyHidden() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("connections")
        let search = app.buttons["openWebSearchSettings"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        XCTAssertTrue(app.navigationBars["Web search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["webSearchKey"].exists)
        XCTAssertFalse(app.buttons["saveWebSearchKey"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Web search setup with a private API key and query approval"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testTheExactQueryIsVisibleBeforeTheSearchDecision() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark", "--web-search-approval-fixture"]
        app.launch()
        let alert = app.alerts["Search the web?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Turku museum opening hours")).firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Exact web query decision recorded UI fixture"; screenshot.lifetime = .keepAlways; add(screenshot)
        alert.buttons["Cancel"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
