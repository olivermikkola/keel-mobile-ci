import XCTest

final class ChatAppearanceUITests: XCTestCase {
    func testDarkConversationAndCopyCode() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        let copy = app.buttons["Copy code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(app.buttons["Code copied"].waitForExistence(timeout: 10))
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
        for _ in 0..<6 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["Code copied"].waitForExistence(timeout: 10))
        capture(app, "Keel largest text code controls - recorded UI content")
        app.openFromMenu("models")
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        capture(app, "Keel largest text model library")
    }

    func testBrandedFirstLaunchInDarkAppearance() {
        let app = XCUIApplication()
        app.launchArguments = ["--appearance-dark", "--first-run-without-system-model"]
        app.launch()
        app.navigationBars.buttons["New chat"].tap()
        XCTAssertTrue(app.buttons["setupLocalModel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["downloadRecommendedModel"].isHittable)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Qwen3 · 0.6B")).firstMatch.exists)
        capture(app, "Keel dark first launch")
        app.buttons["setupLocalModel"].tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["recommended-qwen3-06b"].exists)
        capture(app, "Keel dark model library")
    }

    func testAModelCanBeSetUpFromAnExistingChat() {
        let app = XCUIApplication()
        app.launchArguments = ["--first-run-without-system-model", "--chat-appearance-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["Copy code"].waitForExistence(timeout: 10))
        let download = app.buttons["downloadRecommendedModel"]
        for _ in 0..<6 where !(download.exists && download.isHittable) { app.swipeUp() }
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.isHittable)
        capture(app, "Choose a starter model from an existing conversation")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
