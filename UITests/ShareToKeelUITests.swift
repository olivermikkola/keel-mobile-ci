import XCTest

/// "Send to Keel": what the share extension saves in the App Group is picked
/// up when Keel opens. Photos sent with "Make a video" open Videos with them
/// picked and the sentence filled in. (The share sheet itself belongs to
/// another app and is not driven here.)
final class ShareToKeelUITests: XCTestCase {
    func testSharedPhotosOpenVideosWithThemPicked() {
        let app = XCUIApplication()
        app.launchArguments = ["--shared-photos-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Videos"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Remove photo 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove photo 2"].exists)
        XCTAssertFalse(app.buttons["Remove photo 3"].exists)
        let about = app.descendants(matching: .any).matching(identifier: "videoAbout").firstMatch
        XCTAssertEqual(about.value as? String, "Ruben at the beach")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Shared photos opened in Videos"; shot.lifetime = .keepAlways; add(shot)

        // Opened once: a relaunch does not open it again.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Videos"].waitForExistence(timeout: 3))
    }

    func testSharedPhotosOpenCarouselsOnceAndDoNotStickOnReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["--shared-carousel-fixture"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Carousels"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Remove photo 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove photo 2"].exists)
        XCTAssertFalse(app.buttons["Remove photo 3"].exists)
        let about = app.descendants(matching: .any).matching(identifier: "carouselAbout").firstMatch
        XCTAssertEqual(about.value as? String, "Keel on my phone")

        // Closing Carousels and reopening it from Apps starts clean (no stale shared photos).
        app.navigationBars["Carousels"].buttons["Done"].tap()
        app.openFromMenu("carousels")
        XCTAssertTrue(app.navigationBars["Carousels"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Remove photo 1"].waitForExistence(timeout: 2))
    }
}
