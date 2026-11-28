import XCTest

/// The Videos screen opens from the menu. This fixture has no chat model or
/// narration voice, so it shows what to download and keeps Make video off.
/// The pipeline itself is covered by VideosScreenTests.
final class VideosScreenUITests: XCTestCase {
    func testVideosOpensFromTheMenuAndSaysWhatItNeeds() {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("videos")
        let make = app.buttons["makeVideo"]
        XCTAssertTrue(make.waitForExistence(timeout: 5))
        XCTAssertFalse(make.isEnabled, "No photos, voice or model yet")
        XCTAssertTrue(app.buttons["videoAddPhotos"].exists)
        XCTAssertTrue(app.textFields["videoAbout"].exists || app.textViews["videoAbout"].exists)
        XCTAssertTrue(app.buttons["videoDownloadVoice"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Videos screen before setup"; shot.lifetime = .keepAlways; add(shot)
    }

    func testModelsRejectsUnsupportedCustomKokoroVoiceLinkWithoutDownloading() {
        let app = XCUIApplication()
        app.launchArguments = ["--chat-appearance-fixture", "--appearance-dark"]
        app.launch()
        app.openFromMenu("models")
        let field = app.textFields["kokoroVoiceLink"]
        for _ in 0..<12 {
            if field.exists, field.isHittable, field.frame.maxY < app.frame.maxY - 80 { break }
            app.swipeUp()
        }
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.buttons["importKokoroVoiceFile"].exists)
        let submit = app.buttons["addKokoroVoiceLink"]
        XCTAssertFalse(submit.isEnabled)
        field.tap()
        field.typeText("https://example.test/bf_emma.json")
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let error = app.staticTexts["narrationVoiceError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("huggingface.co"), error.label)
        XCTAssertEqual(field.value as? String, "https://example.test/bf_emma.json")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Custom Kokoro voice rejects non-Hugging-Face link"; shot.lifetime = .keepAlways; add(shot)
    }
}
