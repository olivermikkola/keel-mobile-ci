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
}
