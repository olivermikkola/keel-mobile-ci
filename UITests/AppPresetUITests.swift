import XCTest

final class AppPresetUITests: XCTestCase {
    func testDocsOpensFromAppsPersistsThroughRelaunchAndNewChatLeavesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        app.openFromMenu("apps")
        let docs = app.buttons["app-docs"]
        XCTAssertTrue(docs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["app-slides"].exists)
        for studio in ["images", "videos", "carousels", "decide"] {
            XCTAssertTrue(app.buttons["app-\(studio)"].exists, "app-\(studio)")
        }
        capture(app, "Studios and chat apps in Apps")
        docs.tap()
        let summary = app.staticTexts["Write and revise documents"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        // This fixture does not install or simulate a model. Verify the app
        // choice and onboarding; prompt/tool execution is covered by LocalFilesChatTests.
        XCTAssertTrue(app.buttons["setupLocalModel"].exists)
        capture(app, "Docs preset onboarding without a downloaded model")
        app.terminate()
        app.launchArguments = ["--saved-task-fixture", "--appearance-dark"]
        app.launch()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        capture(app, "Docs preset restored after relaunch")
        // New chat always opens a plain chat: leaving an app is one tap.
        app.buttons["New chat"].tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5))
        capture(app, "New chat leaves the Docs app")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
