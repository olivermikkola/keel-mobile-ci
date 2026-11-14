import XCTest

final class SavedTaskUITests: XCTestCase {
    func testReturnRenameCancelDeleteAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Saved partial reply"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Interrupted"].exists)
        XCTAssertTrue(app.buttons["attachRepository"].label.contains("octocat/Hello-World"))
        app.buttons["New chat"].tap()
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["savedTask-Explain the README"].waitForExistence(timeout: 5))
        capture(app, "Saved tasks with pinned repository and stopped reply")
        let plan = app.buttons["savedTask-Plan a small change"]
        reveal(plan, in: app)
        plan.tap()
        XCTAssertTrue(app.staticTexts["Plan a small change"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["attachRepository"].exists, "A chat without a project shows no project row once it has messages")
        app.buttons["Menu"].tap()
        let options = app.buttons["Task options: Plan a small change"]
        reveal(options, in: app)
        options.tap()
        app.buttons["Rename"].tap()
        let rename = app.alerts["Rename task"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        // UIKit's native alert exposes its field/placeholder, but drops the
        // SwiftUI identifier. Scope the real field to the named alert.
        let field = rename.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        capture(app, "Rename saved task")
        let oldName = try XCTUnwrap(field.value as? String)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
        field.typeText("Review parser")
        rename.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["savedTask-Review parser"].waitForExistence(timeout: 5))
        app.buttons["Task options: Review parser"].tap(); app.buttons["Delete"].tap()
        let deletion = app.alerts["Delete Review parser?"]
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        capture(app, "Saved task cancellation decision")
        deletion.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["savedTask-Review parser"].exists)
        app.buttons["Task options: Review parser"].tap(); app.buttons["Delete"].tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 5))
        capture(app, "Saved task explicit deletion decision")
        deletion.buttons["Delete task"].tap()
        XCTAssertFalse(app.buttons["savedTask-Review parser"].exists)
        app.buttons["savedTask-Explain the README"].tap()
        app.terminate(); app.launchArguments = ["--saved-task-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Saved partial reply"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["attachRepository"].label.contains("octocat/Hello-World"))
        app.buttons["Menu"].tap()
        XCTAssertFalse(app.buttons["savedTask-Review parser"].exists)
        XCTAssertTrue(app.buttons["savedTask-Explain the README"].exists)
        capture(app, "Saved tasks restored after relaunch")
    }

    func testLargestTextKeepsTaskActionsReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Menu"].waitForExistence(timeout: 10))
        app.buttons["Menu"].tap()
        XCTAssertTrue(app.buttons["createSavedTask"].waitForExistence(timeout: 5))
        capture(app, "Saved tasks largest accessibility text")
        app.buttons["createSavedTask"].tap()
        XCTAssertTrue(app.buttons["New chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["attachRepository"].exists, "A fresh chat does not advertise GitHub")
    }

    func testEditProposalModeReturnsWithItsSavedTask() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--saved-task-fixture", "--reset-saved-task-fixture"]
        app.launch()
        let mode = app.descendants(matching: .any).matching(identifier: "directorModeToggle").firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        XCTAssertTrue(mode.label.contains("Enable edit proposals"))
        mode.tap()
        let enabled = NSPredicate(format: "label CONTAINS %@", "Director")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: mode)], timeout: 5), .completed)
        app.buttons["New chat"].tap()
        XCTAssertFalse(mode.exists, "A new task has no repository or inherited edit mode")
        app.buttons["Menu"].tap()
        let saved = app.buttons["savedTask-Explain the README"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: mode)], timeout: 5), .completed)
        app.terminate(); app.launchArguments = ["--saved-task-fixture"]; app.launch()
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        XCTAssertTrue(mode.label.contains("Director"))
        capture(app, "Saved task restores its edit-proposal mode without replay")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // Each menu presentation starts at the top; Apps push older Recents below the fold.
        for _ in 0..<8 {
            if element.exists, element.isHittable, element.frame.minY > 100, element.frame.maxY < app.frame.maxY - 70 { return }
            if element.exists, element.frame.minY <= 100 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
