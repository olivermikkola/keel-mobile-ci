import XCTest

final class ReplySpeechUITests: XCTestCase {
    func testListenAndStopButtonsOnAssistantReply() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        let button = app.buttons["speakReplyButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(button.label, "Read reply aloud")
        button.tap()
        XCTAssertEqual(button.label, "Stop reading reply")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Reply speech active in dark conversation"
        image.lifetime = .keepAlways
        add(image)
        button.tap()
        XCTAssertEqual(button.label, "Read reply aloud")
    }
}
