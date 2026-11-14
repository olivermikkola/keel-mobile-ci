import XCTest

final class ChatAppearanceUITests: XCTestCase {
    func testDarkConversationAndCopyCode() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        let copy = app.buttons["Copy code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(app.buttons["Code copied"].waitForExistence(timeout: 3))
        capture(app, "Keel dark conversation and code copy - recorded UI content")
        XCTAssertFalse(app.buttons["Send message"].isEnabled, "Appearance fixtures must not install or simulate a model.")
    }

    func testLightConversation() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-light"]
        app.launch()
        XCTAssertTrue(app.buttons["Copy code"].waitForExistence(timeout: 10))
        capture(app, "Keel paper conversation - recorded UI content")
    }

    func testLargeTextKeepsCodeCopyAndModelNavigationReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let copy = app.buttons["Copy code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        for _ in 0..<4 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["Code copied"].waitForExistence(timeout: 3))
        capture(app, "Keel largest text code controls - recorded UI content")
        app.openFromMenu("models")
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        capture(app, "Keel largest text model library")
    }

    func testBrandedFirstLaunchInDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--appearance-dark"]
        app.launch()
        app.navigationBars.buttons["New chat"].tap()
        XCTAssertTrue(app.buttons["setupLocalModel"].waitForExistence(timeout: 10))
        capture(app, "Keel dark first launch")
        app.buttons["setupLocalModel"].tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        capture(app, "Keel dark model library")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
