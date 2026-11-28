import XCTest

final class QuickArithmeticUITests: XCTestCase {
    func testFirstChatCanCalculateAndReopenBeforeDownloadingAModel() {
        let app = XCUIApplication()
        app.launch()
        app.navigationBars.buttons["New chat"].tap()
        let setup = app.buttons["setupLocalModel"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        let example = app.buttons["tryCalculation"]
        XCTAssertTrue(example.isHittable)
        example.tap()
        let send = app.buttons["sendMessageButton"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["391"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Calculated on this device"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "First local calculation before downloading a model"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["391"].waitForExistence(timeout: 10))
    }
}
