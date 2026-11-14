import XCTest

final class AppPresetUITests: XCTestCase {
    func testDocsOpensFromAppsAndPersistsThroughNewChatAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        app.buttons["Menu"].tap()
        let docs = app.buttons["app-docs"]
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        capture(app, "Websites Sheets Docs and Study in the Apps menu")
        docs.tap()
        let summary = app.staticTexts["Write and revise documents"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        // This fixture does not install or simulate a model. Verify the app
        // choice and onboarding; prompt/tool execution is covered by LocalFilesChatTests.
        XCTAssertTrue(app.buttons["setupLocalModel"].exists)
        capture(app, "Docs preset onboarding without a downloaded model")
        app.buttons["New chat"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["setupLocalModel"].exists)
        app.terminate()
        app.launchArguments = ["--saved-task-fixture", "--appearance-dark"]
        app.launch()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        capture(app, "Docs preset restored after relaunch")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
