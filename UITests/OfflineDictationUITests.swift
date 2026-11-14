import XCTest

final class OfflineDictationUITests: XCTestCase {
    func testDictationMenuAndCancelPreserveDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        let input = app.descendants(matching: .any).matching(identifier: "localChatInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Keep my draft")
        let addMenu = app.buttons["composerAddMenu"]
        XCTAssertTrue(addMenu.exists)
        // The fixed composer is visible above the keyboard, but XCTest's
        // scroll-to-visible AX action fails for this SwiftUI Menu. Tap its center.
        addMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["offlineDictationMenuOption"].tap()
        XCTAssertTrue(app.navigationBars["Offline dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startOfflineDictation"].isEnabled)
        XCTAssertFalse(app.buttons["insertDictation"].isEnabled)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Offline dictation before microphone permission"; image.lifetime = .keepAlways; add(image)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep my draft")
    }
}
