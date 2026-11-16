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
        let modelPicker = app.buttons["modelPicker"]
        XCTAssertTrue(modelPicker.isHittable, "The model picker must remain reachable at the largest text size.")
        modelPicker.tap()
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

    func testLargeTextWelcomeKeepsSetupAndComposerReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        let setup = app.buttons["setupLocalModel"]
        for _ in 0..<5 where !setup.isHittable { app.swipeUp() }
        XCTAssertTrue(setup.isHittable, "Model setup must be scrollable into view above the composer.")
        let add = app.buttons["composerAddMenu"]
        XCTAssertTrue(add.exists)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        XCTAssertTrue(app.frame.contains(add.frame), "The add control must stay inside the screen.")
        XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled)
        capture(app, "Keel paper welcome at largest text size - no model installed")
        // SwiftUI Menu misreports AX hittability here; use the same direct tap
        // as OfflineDictationUITests and verify the actual interaction.
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dictate = app.buttons["offlineDictationMenuOption"]
        XCTAssertTrue(dictate.waitForExistence(timeout: 5))
        dictate.tap()
        XCTAssertTrue(app.navigationBars["Offline dictation"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        setup.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
