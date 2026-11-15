import XCTest
import UIKit

final class ModelDownloadUITests: XCTestCase {
    func testVerificationFailureHasRetryAndReadableDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["--model-failure-fixture"]
        app.launch(); app.openFromMenu("models")
        let retry = app.buttons["retryModel-9B"]
        for _ in 0..<6 { if retry.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(retry.exists && retry.isHittable && retry.isEnabled)
        XCTAssertTrue(app.staticTexts["modelDownloadError"].exists)
        app.buttons["Download details"].tap()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Model verification recovery and details"; image.lifetime = .keepAlways; add(image)
    }

    func testPartialDownloadControlsAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--partial-model-fixture", "-UIPreferredContentSizeCategoryName",
                               UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        app.openFromMenu("models")
        let resume = app.buttons["resumeModel-4B"]
        for _ in 0..<6 {
            if resume.exists && resume.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(resume.exists && resume.isHittable)
        XCTAssertTrue(resume.isEnabled)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Paused model download at largest text size"; image.lifetime = .keepAlways; add(image)
    }

    func testPartialSurvivesRelaunchAndDiscardRequiresConfirmation() {
        let app = XCUIApplication()
        app.launchArguments += ["--partial-model-fixture"]
        app.launch()
        app.openFromMenu("models")
        let resume = app.buttons["resumeModel-4B"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Selected"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Paused model download ready to resume"; image.lifetime = .keepAlways; add(image)
        app.terminate(); app.launchArguments = []; app.launch()
        app.openFromMenu("models")
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        app.buttons["discardModel-4B"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        let confirmation = XCTAttachment(screenshot: app.screenshot())
        confirmation.name = "Explicit partial-download discard confirmation"; confirmation.lifetime = .keepAlways; add(confirmation)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(resume.exists)
        app.buttons["discardModel-4B"].tap()
        app.alerts.buttons["Discard download"].tap()
        XCTAssertTrue(app.buttons["Download Bonsai 2 · 4B"].waitForExistence(timeout: 5))
        XCTAssertFalse(resume.exists)
        app.terminate(); app.launch()
        app.openFromMenu("models")
        XCTAssertTrue(app.buttons["Download Bonsai 2 · 4B"].waitForExistence(timeout: 5))
    }
}
