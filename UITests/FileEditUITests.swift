import XCTest

final class FileEditUITests: XCTestCase {
    private func launchApp(reset: Bool = true, largest: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-recording", withExtension: "json"))
        app.launchArguments = ["--edit-review-fixture", "--recorded-repository"]
        if reset { app.launchArguments += ["--reset-edit-review-fixture"] }
        if largest { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["KEEL_RECORDED_REPOSITORY"] = try String(contentsOf: fixture, encoding: .utf8)
        app.launch()
        return app
    }
    func testReviewCancelApplyAndRelaunch() throws {
        let app = try launchApp()
        let review = app.buttons["openTaskChanges"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        XCTAssertTrue(app.buttons["reviewApplyEdit"].waitForExistence(timeout: 5))
        let removed = app.descendants(matching: .any).matching(identifier: "editDiffLine-0").firstMatch
        let added = app.descendants(matching: .any).matching(identifier: "editDiffLine-1").firstMatch
        XCTAssertTrue(removed.label.contains("Remove line 1: Hello World!"))
        XCTAssertTrue(added.label.contains("Add line 1: Hello Keel!"))
        capture(app, "Pending file edit with exact line-numbered diff - recorded fixture")
        app.buttons["reviewApplyEdit"].tap()
        let confirmation = app.alerts["Apply this change to the task?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["reviewApplyEdit"].exists)
        let decision = app.descendants(matching: .any).matching(identifier: "reviewEditDecision").firstMatch
        XCTAssertFalse(decision.exists)
        app.buttons["reviewApplyEdit"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        capture(app, "Explicit apply-to-task decision")
        confirmation.buttons["Apply reviewed change"].tap()
        XCTAssertTrue(decision.waitForExistence(timeout: 15))
        XCTAssertTrue(decision.label.contains("Applied to task"))
        XCTAssertFalse(app.buttons["reviewApplyEdit"].exists)
        capture(app, "Reviewed change applied to the task - recorded HTTP")
        app.buttons["Done"].tap()
        app.terminate()
        app.launchArguments = ["--edit-review-fixture", "--recorded-repository"]
        app.launch()
        XCTAssertTrue(app.buttons["openTaskChanges"].waitForExistence(timeout: 10))
        app.buttons["openTaskChanges"].tap()
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        XCTAssertTrue(decision.label.contains("Applied to task"))
        XCTAssertFalse(app.buttons["reviewApplyEdit"].exists)
        capture(app, "Applied change restored without reapplying")
    }

    func testDiscardPersistsAndLargestTextKeepsApprovalReachable() throws {
        let app = try launchApp(largest: true)
        XCTAssertTrue(app.buttons["openTaskChanges"].waitForExistence(timeout: 10))
        app.buttons["openTaskChanges"].tap()
        XCTAssertTrue(app.buttons["reviewApplyEdit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reviewApplyEdit"].isHittable)
        XCTAssertTrue(app.buttons["reviewDiscardEdit"].isHittable)
        capture(app, "File review at largest accessibility text")
        app.buttons["reviewDiscardEdit"].tap()
        let decision = app.descendants(matching: .any).matching(identifier: "reviewEditDecision").firstMatch
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        XCTAssertTrue(decision.label.contains("Proposal discarded"))
        app.buttons["Done"].tap()
        app.terminate(); app.launchArguments = ["--edit-review-fixture", "--recorded-repository"]; app.launch()
        XCTAssertTrue(app.buttons["openTaskChanges"].waitForExistence(timeout: 10))
        app.buttons["openTaskChanges"].tap()
        XCTAssertTrue(decision.waitForExistence(timeout: 5))
        XCTAssertTrue(decision.label.contains("Proposal discarded"))
        XCTAssertFalse(app.buttons["reviewApplyEdit"].exists)
    }

    func testPreviewShowsTheProposedPageWithItsStylesheetAndNoNetwork() throws {
        let app = XCUIApplication()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-recording", withExtension: "json"))
        app.launchArguments = ["--edit-review-fixture", "--reset-edit-review-fixture", "--web-preview-fixture", "--recorded-repository"]
        app.launchEnvironment["KEEL_RECORDED_REPOSITORY"] = try String(contentsOf: fixture, encoding: .utf8)
        app.launch()
        let review = app.buttons["openTaskChanges"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        let preview = app.buttons["previewPage"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.tap()
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Hello from Keel"].waitForExistence(timeout: 15))
        // The stylesheet is a separate proposed file; the page's script sees it applied.
        XCTAssertTrue(page.staticTexts["Heading color rgb(255, 0, 0)"].waitForExistence(timeout: 5))
        XCTAssertTrue(page.staticTexts["Network blocked"].waitForExistence(timeout: 10))
        capture(app, "Preview of a proposed page with its proposed stylesheet")
        app.navigationBars["site/index.html"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["reviewApplyEdit"].waitForExistence(timeout: 5))
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
