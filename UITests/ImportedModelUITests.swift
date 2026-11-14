import XCTest

final class ImportedModelUITests: XCTestCase {
    func testImportEntryExplainsSupportedModelsAndOpensFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("models")
        let button = app.buttons["importModelFile"]
        // A partly visible row can be hittable while its center is behind
        // the home indicator. Bring the whole control into the safe viewport.
        for _ in 0..<12 {
            if button.exists, button.isHittable, button.frame.maxY < app.frame.maxY - 80 { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        XCTAssertLessThan(button.frame.maxY, app.frame.maxY - 80)
        let entry = XCTAttachment(screenshot: app.screenshot())
        entry.name = "Import your own GGUF model entry"; entry.lifetime = .keepAlways; add(entry)
        button.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "GGUF import through the native Files picker"; picker.lifetime = .keepAlways; add(picker)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
    }
}
