import XCTest

final class OfflineDictationUITests: XCTestCase {
    func testDictationMenuAndCancelPreserveDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        let input = app.descendants(matching: .any).matching(identifier: "localChatInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Keep my draft")
        let mic = app.buttons["dictateButton"]
        XCTAssertTrue(mic.exists, "The mic stays next to a typed draft")
        XCTAssertGreaterThanOrEqual(mic.frame.width, 44)
        XCTAssertGreaterThanOrEqual(mic.frame.height, 44)
        mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
