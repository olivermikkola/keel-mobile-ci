import XCTest

final class PairingUITests: XCTestCase {
    func testFirstLaunchAndInvalidPairing() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["setupLocalModel"].waitForExistence(timeout: 10))
        let chat = XCTAttachment(screenshot: app.screenshot())
        chat.name = "On-device chat first launch"
        chat.lifetime = .keepAlways
        add(chat)
        XCTAssertFalse(app.buttons["Send message"].isEnabled)
        app.buttons["setupLocalModel"].tap()
        XCTAssertTrue(app.buttons["Download Bonsai 2 · 4B"].waitForExistence(timeout: 5) || app.buttons["resumeModel-4B"].exists)
        let models = XCTAttachment(screenshot: app.screenshot())
        models.name = "Local model library"
        models.lifetime = .keepAlways
        add(models)
        app.tabBars.buttons["Connect"].tap()
        // Paired mode is advanced: the Connect screen leads with on-phone features.
        XCTAssertTrue(app.buttons["advancedPairing"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["gatewayAddress"].exists)
        app.buttons["advancedPairing"].tap()
        XCTAssertTrue(app.textFields["gatewayAddress"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native iPhone pairing"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["connectGateway"].tap()
        XCTAssertTrue(app.alerts["Gateway"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "HTTPS")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse(app.tabBars.buttons["Workspace"].exists)
        XCTAssertFalse(app.tabBars.buttons["Approvals"].exists)
    }
}
