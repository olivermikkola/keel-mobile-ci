import XCTest

final class OfflineDictationUITests: XCTestCase {
    func testDictationTypesIntoTheMessageBoxAfterTheDraft() {
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
        XCTAssertEqual(mic.label, "Dictate")
        mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let dictated = NSPredicate(format: "value == %@", "Keep my draft Hello from dictation")
        expectation(for: dictated, evaluatedWith: input)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.navigationBars["Offline dictation"].exists, "No separate dictation screen")
        XCTAssertEqual(mic.label, "Stop dictation")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Dictation typing into the message box"; image.lifetime = .keepAlways; add(image)

        mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let stopped = NSPredicate(format: "label == %@", "Dictate")
        expectation(for: stopped, evaluatedWith: mic)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(input.value as? String, "Keep my draft Hello from dictation", "Stopping keeps the words")
    }
}
