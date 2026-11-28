import XCTest

/// The short-video draft screen on a fixture video (real renderer, synthetic
/// narration; no model). Screenshots go to the test results.
final class ShortVideoDraftUITests: XCTestCase {
    func testDraftPlaysShowsTheTimelineAndSendsAChange() {
        let app = XCUIApplication()
        app.launchArguments = ["--short-video-draft-fixture", "--appearance-dark"]
        app.launch()
        let video = app.otherElements["draftVideo"]
        XCTAssertTrue(video.waitForExistence(timeout: 120), "the fixture renders, then the draft opens")
        XCTAssertTrue(app.staticTexts["Kokoro · Heart"].exists)
        XCTAssertTrue(app.buttons["Previous scene"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Save to Photos"].exists)

        // Jump to the overlay scene and play a moment.
        app.buttons["Next scene"].tap()
        app.buttons["Next scene"].tap()
        app.buttons["draftPlay"].tap()
        sleep(2)
        XCTAssertTrue(app.buttons["Pause"].exists, "playing")
        capture(app, "Short video draft - fixture video, synthetic narration")

        let field = app.textFields["draftChange"].exists ? app.textFields["draftChange"] : app.textViews["draftChange"]
        field.tap()
        field.typeText("Make the second scene shorter")
        XCTAssertTrue(app.buttons["draftSendChange"].waitForExistence(timeout: 5))
        capture(app, "Short video draft - describing a change")
        app.buttons["draftSendChange"].tap()
        XCTAssertTrue(app.staticTexts["draftFixtureSent"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["draftFixtureSent"].label, "Sent: Make the second scene shorter")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
