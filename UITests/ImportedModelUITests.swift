import XCTest

final class ImportedModelUITests: XCTestCase {
    func testPastedModelLinkRejectsUnsupportedHostWithoutStartingADownload() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("models")
        let field = app.textFields["modelLink"]
        for _ in 0..<12 {
            if field.exists, field.isHittable, field.frame.maxY < app.frame.maxY - 80 { break }
            app.swipeUp()
        }
        XCTAssertTrue(field.isHittable)
        let submit = app.buttons["addModelLink"]
        XCTAssertFalse(submit.isEnabled)
        field.tap()
        field.typeText("https://example.test/tiny.gguf")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let error = app.staticTexts["modelDownloadError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("huggingface.co"), error.label)
        XCTAssertEqual(field.value as? String, "https://example.test/tiny.gguf", "A rejected link stays editable")
        app.navigationBars["Models"].tap()
        for _ in 0..<4 {
            if error.isHittable { break }
            app.swipeUp()
        }
        let entry = XCTAttachment(screenshot: app.screenshot())
        entry.name = "Pasted model link refuses an unsupported host"; entry.lifetime = .keepAlways; add(entry)
    }

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
        // The native Files process may take several seconds to start on shared CI.
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "GGUF import through the native Files picker"; picker.lifetime = .keepAlways; add(picker)
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
    }
}
